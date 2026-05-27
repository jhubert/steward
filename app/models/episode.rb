class Episode < ApplicationRecord
  include WorkspaceScoped

  has_neighbors :embedding

  belongs_to :user
  belongs_to :agent
  belongs_to :conversation

  validates :channel, :started_at, :ended_at, presence: true

  scope :for_user_agent, ->(user, agent) { where(user_id: user.id, agent_id: agent.id) }
  scope :chronological, -> { order(started_at: :asc) }
  scope :recent, -> { order(started_at: :desc) }
  scope :with_embedding, -> { where.not(embedding: nil) }

  def message_range
    return Message.none unless first_message_id && last_message_id
    conversation.messages.where(id: first_message_id..last_message_id).chronological
  end
end
