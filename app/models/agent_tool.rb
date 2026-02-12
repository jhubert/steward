class AgentTool < ApplicationRecord
  include WorkspaceScoped

  encrypts :credentials_json

  belongs_to :agent
  has_many :tool_executions, dependent: :destroy

  validates :name, presence: true,
                   format: { with: /\A[a-z][a-z0-9_]*\z/, message: "must be lowercase snake_case" },
                   uniqueness: { scope: [:workspace_id, :agent_id] }
  validates :description, presence: true
  validates :input_schema, presence: true
  validates :command_template, presence: true
  validates :timeout_seconds, numericality: { in: 1..300 }

  scope :enabled, -> { where(enabled: true) }

  def credentials
    return {} if credentials_json.blank?
    JSON.parse(credentials_json)
  rescue JSON::ParserError
    {}
  end

  def credentials=(hash)
    self.credentials_json = hash.present? ? hash.to_json : nil
  end

  def to_anthropic_tool
    { name: name, description: description, input_schema: input_schema }
  end
end
