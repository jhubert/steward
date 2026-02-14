class Conversation < ApplicationRecord
  include WorkspaceScoped

  belongs_to :user
  belongs_to :agent
  has_many :messages, dependent: :destroy
  has_one :state, class_name: 'ConversationState', dependent: :destroy
  has_many :memory_items, dependent: :nullify
  has_many :scheduled_tasks, dependent: :destroy

  validates :channel, presence: true

  scope :active, -> { where(status: 'active') }

  COMPACTION_THRESHOLD = 20
  EXTRACTION_THRESHOLD = 10

  def ensure_state!
    state || create_state!(workspace: workspace, user: user)
  end

  def needs_compaction?
    last_summarized = state&.summarized_through_message_id || 0
    messages.where('id > ?', last_summarized).count >= COMPACTION_THRESHOLD
  end

  def needs_extraction?
    last_extracted = state&.extracted_through_message_id || 0
    messages.where('id > ?', last_extracted).count >= EXTRACTION_THRESHOLD
  end

  # Find or create a conversation for a given channel and external key.
  def self.find_or_start(user:, agent:, channel:, external_thread_key:)
    find_or_create_by!(
      workspace: user.workspace,
      user: user,
      agent: agent,
      channel: channel,
      external_thread_key: external_thread_key
    )
  end
end
