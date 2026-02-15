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

  def session_break_needed?(current_message)
    last_msg = messages.where.not(id: current_message.id).chronological.last
    return false unless last_msg

    gap_seconds = current_message.created_at - last_msg.created_at
    gap_seconds >= agent.session_break_hours.hours.to_i
  end

  def compact_for_session_break!(current_message)
    s = ensure_state!
    unsummarized = s.unsummarized_messages.where.not(id: current_message.id)
    return if unsummarized.empty?

    last_msg = messages.where.not(id: current_message.id).chronological.last
    gap_hours = ((current_message.created_at - last_msg.created_at) / 3600.0).round(1)

    summarizer = Compaction::Summarizer.new(agent: agent)
    new_summary = summarizer.call(
      existing_summary: s.summary,
      messages: unsummarized.limit(50)
    )
    zone = ActiveSupport::TimeZone[agent.settings&.dig("timezone") || "Pacific Time (US & Canada)"]
    prev_time = last_msg.created_at.in_time_zone(zone).strftime("%-I:%M %p %Z on %A")
    now_time = current_message.created_at.in_time_zone(zone).strftime("%-I:%M %p %Z on %A")
    gap_notice = "\n\n---\nSession break: #{gap_hours} hours passed (previous: #{prev_time}, now: #{now_time})."

    s.advance_summary!(new_summary + gap_notice, unsummarized.last.id)
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
