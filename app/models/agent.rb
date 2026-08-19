class Agent < ApplicationRecord
  include WorkspaceScoped

  # Current models first, then the older ones still assigned to live agents.
  # Note: the 5-series models run with adaptive thinking on by default, so any
  # call using them must either budget max_tokens for thinking or pass
  # thinking: { type: 'disabled' } (see Memory::Extractor and friends).
  AVAILABLE_MODELS = %w[
    claude-opus-5
    claude-sonnet-5
    claude-haiku-4-5-20251001
    claude-opus-4-7
    claude-opus-4-6
    claude-sonnet-4-6
  ].freeze

  DEFAULT_MODEL = 'claude-sonnet-5'
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
      tool = agent_tools.find_or_initialize_by(name: defn[:name])
      tool.workspace ||= workspace
      tool.enabled = true if tool.new_record?
      tool.description = defn[:description]
      tool.input_schema = defn[:input_schema]
      tool.command_template = defn[:command_template]
      tool.working_directory = defn[:working_directory]
      tool.timeout_seconds = defn[:timeout_seconds]
      tool.save!
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

  # Returns true when every recipient is a principal of this agent — used by
  # the prepare-first gate to auto-execute purely-internal email actions.
  # Recipients must be pre-resolved lowercase addresses (the gate's prepare
  # phase produces these from the tool input + Gmail thread fetch).
  def auto_approve_recipients?(recipients)
    return false if recipients.blank?
    set = principal_email_set
    recipients.all? { |addr| set.include?(addr.to_s.downcase) }
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
