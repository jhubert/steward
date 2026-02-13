class Agent < ApplicationRecord
  include WorkspaceScoped

  has_many :conversations, dependent: :destroy
  has_many :agent_principals, dependent: :destroy
  has_many :principals, through: :agent_principals, source: :user
  has_many :agent_tools, dependent: :destroy

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

  def token_budgets
    defaults = { 'agent_core' => 800, 'skills' => 2000, 'state' => 1500, 'history' => 4000, 'response' => 4000, 'principal_context' => 1200, 'retrieval' => 800 }
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

  def principal_roster
    agent_principals.includes(:user)
  end

  def enabled_tools
    agent_tools.enabled
  end

  def has_tools?
    enabled_tools.any?
  end

  def telegram_bot_token
    settings&.dig('telegram_bot_token') || Rails.application.credentials.dig(:telegram, :bot_token)
  end
end
