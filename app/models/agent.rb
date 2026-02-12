class Agent < ApplicationRecord
  include WorkspaceScoped

  has_many :conversations, dependent: :destroy

  validates :name, presence: true
  validates :system_prompt, presence: true

  def model
    settings&.dig('model') || 'claude-sonnet-4-5-20250929'
  end

  def summarization_model
    settings&.dig('summarization_model') || 'claude-sonnet-4-5-20250929'
  end

  def token_budgets
    defaults = { 'agent_core' => 800, 'skills' => 2000, 'state' => 1500, 'history' => 4000, 'response' => 4000 }
    defaults.merge(settings&.dig('token_budgets') || {})
  end

  def telegram_bot_token
    settings&.dig('telegram_bot_token') || Rails.application.credentials.dig(:telegram, :bot_token)
  end
end
