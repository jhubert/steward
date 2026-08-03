class MemoryItem < ApplicationRecord
  include WorkspaceScoped

  has_neighbors :embedding

  belongs_to :user
  belongs_to :agent, optional: true
  belongs_to :conversation, optional: true
  belongs_to :supersedes, class_name: "MemoryItem", optional: true
  has_one :superseded_by, class_name: "MemoryItem", foreign_key: :supersedes_id

  AGENT_VISIBILITY = "agent".freeze
  SHARED_VISIBILITY = "workspace".freeze
  VISIBILITIES = [AGENT_VISIBILITY, SHARED_VISIBILITY].freeze

  # Who a memory is *about*, as opposed to who can read it. World facts are
  # things an agent looked up (market data, news) rather than learned about the
  # person; they stay searchable but never enter prompt context.
  SUBJECT_SCOPES = %w[principal world].freeze

  # How long a fact stays live. `transient` covers things with an obvious shelf
  # life (a scheduled date, this quarter's numbers); `permanent` and `durable`
  # never auto-expire and differ only as a hint to future supersession logic.
  DURABILITIES = %w[permanent durable transient].freeze
  TRANSIENT_TTL = 30.days

  validates :content, presence: true
  validates :visibility, inclusion: { in: VISIBILITIES }
  validates :subject_scope, inclusion: { in: SUBJECT_SCOPES }

  scope :with_embedding, -> { where.not(embedding: nil) }

  # Current (not-superseded) memories. Most callers should use this — the
  # supersession chain is for audit/history, not for active prompt context.
  scope :current, -> { where(superseded_at: nil) }

  # The shared principal core: facts about a person that every agent serving
  # them can read, as opposed to one agent's private working knowledge.
  scope :shared_core, -> { where(visibility: SHARED_VISIBILITY) }
  scope :agent_private, -> { where(visibility: AGENT_VISIBILITY) }

  # Knowledge about the principal, as opposed to world facts an agent picked up
  # while researching. Only these belong in prompt context.
  scope :about_principal, -> { where(subject_scope: "principal") }
  scope :about_world, -> { where(subject_scope: "world") }

  scope :unexpired, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }

  def shared?
    visibility == SHARED_VISIBILITY
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  # Translates a durability class into a concrete expiry.
  def self.expiry_for(durability)
    durability.to_s == "transient" ? TRANSIENT_TTL.from_now : nil
  end

  # Readable by `agent`: anything that agent extracted itself, plus the shared
  # core — minus categories that are never appropriate to pass between agents.
  scope :readable_by_agent, ->(agent) {
    where(
      "memory_items.agent_id = :agent_id OR (" \
      "memory_items.visibility = :shared AND (" \
      "memory_items.category IS NULL OR memory_items.category NOT IN (:private)))",
      agent_id: agent&.id,
      shared: SHARED_VISIBILITY,
      private: Memory::Extractor::PRIVATE_CATEGORIES
    )
  }

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
