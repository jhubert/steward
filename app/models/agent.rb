class Agent < ApplicationRecord
  include WorkspaceScoped

  AVAILABLE_MODELS = %w[
    claude-opus-4-7
    claude-sonnet-4-6
    claude-haiku-4-5-20251001
  ].freeze

  DEFAULT_MODEL = 'claude-sonnet-4-6'
  DEFAULT_EXTRACTION_MODEL = 'claude-haiku-4-5-20251001'

  has_many :conversations, dependent: :destroy
  has_many :agent_principals, dependent: :destroy
  has_many :principals, through: :agent_principals, source: :user
  has_many :agent_tools, dependent: :destroy
  has_many :scheduled_tasks, dependent: :destroy
  has_many :pairing_codes, dependent: :destroy
  has_many :pending_actions, dependent: :destroy

  validates :name, presence: true
  validates :system_prompt, presence: true

  def model
    settings&.dig('model') || DEFAULT_MODEL
  end

  def summarization_model
    settings&.dig('summarization_model') || DEFAULT_MODEL
  end

  def extraction_model
    settings&.dig('extraction_model') || DEFAULT_EXTRACTION_MODEL
  end

  def max_tool_rounds
    settings&.dig('max_tool_rounds') || 10
  end

  def session_break_hours
    settings&.dig('session_break_hours') || 4
  end

  def token_budgets
    defaults = { 'agent_core' => 800, 'skills' => 2000, 'state' => 1500, 'history' => 4000, 'response' => 4000, 'principal_context' => 1200, 'retrieval' => 800, 'background_activity' => 800 }
    defaults.merge(settings&.dig('token_budgets') || {})
  end

  def principal_mode?
    agent_principals.any?
  end

  def principal?(user)
    agent_principals.exists?(user: user)
  end

  def principal_record(user)
    agent_principals.find_by(user: user)
  end

  def fellow_principals(user)
    agent_principals.where.not(user: user).includes(:user)
  end

  def fellow_agents(user)
    agent_ids = AgentPrincipal.where(user: user)
                              .where.not(agent_id: id)
                              .select(:agent_id)
    Agent.where(id: agent_ids)
  end

  def brief_description
    return nil if system_prompt.blank?
    system_prompt[/[^.!?]*[.!?]/] || system_prompt.truncate(100)
  end

  def paired?(user)
    pairing_codes.where(redeemed_by: user).where.not(redeemed_at: nil).exists?
  end

  def accessible_by?(user)
    principal?(user) || paired?(user)
  end

  def principal_roster
    agent_principals.includes(:user)
  end

  def enabled_tools
    agent_tools.enabled
  end

  def has_tools?
    enabled_tools.any?
  end

  def enable_skill!(skill_name)
    skill = Skills::Registry.instance.find(skill_name)
    raise ArgumentError, "Unknown skill: #{skill_name}" unless skill

    skill.tool_definitions.each do |defn|
      agent_tools.find_or_create_by!(name: defn[:name]) do |tool|
        tool.workspace = workspace
        tool.description = defn[:description]
        tool.input_schema = defn[:input_schema]
        tool.command_template = defn[:command_template]
        tool.working_directory = defn[:working_directory]
        tool.timeout_seconds = defn[:timeout_seconds]
        tool.enabled = true
      end
    end
  end

  def disable_skill!(skill_name)
    skill = Skills::Registry.instance.find(skill_name)
    raise ArgumentError, "Unknown skill: #{skill_name}" unless skill

    tool_names = skill.tool_definitions.map { |d| d[:name] }
    agent_tools.where(name: tool_names).destroy_all
  end

  def enabled_skill_names
    registry = Skills::Registry.instance
    registry.all.select do |skill|
      tool_names = skill.tool_definitions.map { |d| d[:name] }
      tool_names.any? && tool_names.all? { |n| agent_tools.exists?(name: n) }
    end.map(&:name)
  end

  def memory_sharing?
    settings&.dig('memory_sharing') == true
  end

  # Names of tools (virtual or agent_tool) that must be approved before execution.
  # Configured via agent.settings["approval_required_tools"] = ["send_email", ...].
  def approval_required_tools
    Array(settings&.dig('approval_required_tools')).map(&:to_s)
  end

  def approval_required?(tool_name)
    approval_required_tools.include?(tool_name.to_s)
  end

  # Returns true when an otherwise-approval-required call can be auto-executed
  # because the action is purely internal — e.g. an email whose entire recipient
  # set is principals of this agent. Saves the approver from rubber-stamping
  # emails they themselves are receiving.
  def auto_approve?(tool_name, input)
    recipients = case tool_name.to_s
                 when "send_email", "gmail_new_thread"
                   email_addresses_from(input)
                 when "gmail_reply"
                   reply_recipients_for(input)
                 else
                   return false
                 end
    return false if recipients.empty?
    recipients.all? { |addr| principal_email_set.include?(addr) }
  end

  # For gmail_reply: derive the thread's other-party emails from our own DB.
  # `--reply-all` sends to every participant except the agent itself, so the
  # gate-relevant set is "participants minus self".
  def reply_recipients_for(input)
    thread_id = input["thread_id"].to_s.strip
    return [] if thread_id.blank?

    conv = Conversation.unscoped.find_by(
      workspace_id: workspace_id,
      agent_id: id,
      channel: "email",
      external_thread_key: "gmail:#{thread_id}"
    )
    return [] unless conv

    own = settings&.dig("gog_email").to_s.downcase
    Array(conv.metadata&.dig("email_participants")).filter_map do |p|
      email = p["email"].to_s.downcase
      next if email.blank? || email == own
      email
    end
  end

  # Lowercased email addresses for every principal (including any aliases
  # tracked in external_ids["emails"]).
  def principal_email_set
    Set.new.tap do |set|
      agent_principals.includes(:user).each do |ap|
        u = ap.user
        set << u.email.to_s.downcase if u.email.present?
        Array(u.external_ids&.dig("emails")).each { |e| set << e.to_s.downcase }
      end
    end
  end

  # Extracts lowercased email addresses from a send_email-shaped input hash.
  # Accepts comma-separated strings and "Name <addr>" forms in either field.
  def email_addresses_from(input)
    raw = "#{input['to']},#{input['cc']}"
    raw.split(",").filter_map do |part|
      addr = part.to_s.sub(/.*<([^>]+)>.*/, '\1').strip.downcase
      addr.presence
    end
  end

  # The user who approves outbound actions. Configurable via
  # agent.settings["approval_approver_user_id"]; falls back to the first principal.
  def approver_user
    explicit_id = settings&.dig('approval_approver_user_id')
    return User.find_by(id: explicit_id) if explicit_id
    agent_principals.order(:created_at).first&.user
  end

  # Returns the conversation we'd use to send an approval ping to the approver.
  # v1: must be an existing Telegram thread between the approver and this agent.
  def approval_conversation_for(user)
    return nil unless user
    Conversation.unscoped
                .where(agent_id: id, user_id: user.id, channel: "telegram")
                .order(updated_at: :desc)
                .first
  end

  def email_handle
    settings&.dig('email_handle')
  end

  # Returns GOG env vars if the agent has its own authenticated Google account.
  # Requires agent.settings["gog_email"] to be set (the agent's own Gmail address).
  # Finds the principal whose gog_account matches and returns their GOG credentials.
  # Returns nil if the agent should fall back to Postmark.
  def own_gog_env
    agent_gog_email = settings&.dig("gog_email").to_s.downcase.presence
    return nil unless agent_gog_email

    agent_principals.each do |ap|
      creds = ap.credentials
      next unless creds["gog_keyring_password"].present?
      next unless creds["gog_account"].to_s.downcase == agent_gog_email

      user_gog_dir = Rails.root.join("data", "gog", ap.user_id.to_s).to_s
      return {
        "XDG_CONFIG_HOME" => user_gog_dir,
        "GOG_KEYRING_PASSWORD" => creds["gog_keyring_password"],
        "GOG_KEYRING_BACKEND" => "file",
        "GOG_ACCOUNT" => agent_gog_email
      }
    end

    nil
  end

  def self.find_by_email_handle(handle)
    return nil if handle.blank?
    unscoped.where("settings->>'email_handle' = ?", handle.downcase).first
  end

  def telegram_bot_token
    settings&.dig('telegram_bot_token') || Rails.application.credentials.dig(:telegram, :bot_token) || ENV["TELEGRAM_BOT_TOKEN"]
  end

  def trigger(user:, content:)
    conversation = Conversation.find_or_start(
      user: user,
      agent: self,
      channel: "background",
      external_thread_key: "background:#{id}:#{user.id}"
    )

    message = conversation.messages.create!(
      workspace: workspace,
      user: user,
      role: "user",
      content: content,
      metadata: { "source" => "trigger" }
    )

    ProcessMessageJob.perform_later(message.id)
    message
  end

  def principal_env_for(user)
    principal = agent_principals.find_by(user: user)
    return {} unless principal&.credentials&.key?("gog_keyring_password")

    user_gog_dir = Rails.root.join("data", "gog", user.id.to_s).to_s
    env = {
      "XDG_CONFIG_HOME" => user_gog_dir,
      "GOG_KEYRING_PASSWORD" => principal.credentials["gog_keyring_password"],
      "GOG_KEYRING_BACKEND" => "file"
    }
    env["GOG_ACCOUNT"] = principal.credentials["gog_account"] if principal.credentials["gog_account"].present?
    env
  end

  def register_telegram_webhook!
    token = telegram_bot_token
    return { ok: false, description: "No bot token configured" } unless token.present?

    url = "https://steward.boardwise.co/webhooks/telegram/#{id}"
    response = HTTPX.post("https://api.telegram.org/bot#{token}/setWebhook", json: { url: url })
    body = JSON.parse(response.body.to_s)
    { ok: body["ok"], description: body["description"] }
  end
end
