class Agent < ApplicationRecord
  include WorkspaceScoped

  has_many :conversations, dependent: :destroy
  has_many :agent_principals, dependent: :destroy
  has_many :principals, through: :agent_principals, source: :user
  has_many :agent_tools, dependent: :destroy
  has_many :scheduled_tasks, dependent: :destroy
  has_many :pairing_codes, dependent: :destroy

  validates :name, presence: true
  validates :system_prompt, presence: true

  def model
    settings&.dig('model') || 'claude-sonnet-4-5-20250929'
  end

  def summarization_model
    settings&.dig('summarization_model') || 'claude-sonnet-4-5-20250929'
  end

  def extraction_model
    settings&.dig('extraction_model') || 'claude-haiku-4-5-20251001'
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

  def email_handle
    settings&.dig('email_handle')
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

    domain = ENV.fetch("STEWARD_DOMAIN", "steward.boardwise.co")
    url = "https://#{domain}/webhooks/telegram/#{id}"
    response = HTTPX.post("https://api.telegram.org/bot#{token}/setWebhook", json: { url: url })
    body = JSON.parse(response.body.to_s)
    { ok: body["ok"], description: body["description"] }
  end
end
