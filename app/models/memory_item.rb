class MemoryItem < ApplicationRecord
  include WorkspaceScoped

  has_neighbors :embedding

  belongs_to :user
  belongs_to :agent, optional: true
  belongs_to :conversation, optional: true
  belongs_to :supersedes, class_name: "MemoryItem", optional: true
  has_one :superseded_by, class_name: "MemoryItem", foreign_key: :supersedes_id

  validates :content, presence: true

  scope :with_embedding, -> { where.not(embedding: nil) }

  # Current (not-superseded) memories. Most callers should use this — the
  # supersession chain is for audit/history, not for active prompt context.
  scope :current, -> { where(superseded_at: nil) }

  # Mark this memory as replaced by another. Both records remain in the
  # database for audit; only `superseded_at` flips so the `current` scope
  # filters it out.
  def supersede!(by:)
    return if superseded_at.present?
    transaction do
      by.update!(supersedes_id: id)
      update!(superseded_at: Time.current)
    end
  end
end
