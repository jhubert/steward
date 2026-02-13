class MemoryItem < ApplicationRecord
  include WorkspaceScoped

  has_neighbors :embedding

  belongs_to :user
  belongs_to :conversation, optional: true

  validates :content, presence: true

  scope :with_embedding, -> { where.not(embedding: nil) }
end
