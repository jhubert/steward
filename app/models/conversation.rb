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
  IDLE_HOURS = 6

  def ensure_state!
    state || ConversationState.create_or_find_by!(conversation: self, workspace: workspace, user: user)
  end

  def needs_compaction?
    last_summarized = state&.summarized_through_message_id || 0
    return true if stale_for_compaction?(last_summarized)
    messages.where('id > ?', last_summarized).count >= COMPACTION_THRESHOLD
  end

  def needs_extraction?
    last_extracted = state&.extracted_through_message_id || 0
    return true if stale_for_extraction?(last_extracted)
    messages.where('id > ?', last_extracted).count >= EXTRACTION_THRESHOLD
  end

  # Idle-trigger: there's unsummarized content AND the most recent unsummarized
  # message is older than IDLE_HOURS — flush it before it falls into the gap.
  def stale_for_compaction?(last_summarized = nil)
    last_summarized ||= state&.summarized_through_message_id || 0
    last = messages.where('id > ?', last_summarized).order(:id).last
    return false unless last
    last.created_at < IDLE_HOURS.hours.ago
  end

  def stale_for_extraction?(last_extracted = nil)
    last_extracted ||= state&.extracted_through_message_id || 0
    last = messages.where('id > ?', last_extracted).order(:id).last
    return false unless last
    last.created_at < IDLE_HOURS.hours.ago
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

    first_id = unsummarized.first.id
    last_id  = unsummarized.last.id
    s.advance_summary!(new_summary + gap_notice, last_id)

    # Capture the just-closed session as a searchable Episode so the agent
    # can later recall "we talked about X on Tuesday" without grepping
    # transcripts. Async — never blocks the user-facing reply.
    BuildEpisodeJob.perform_later(id, first_id, last_id)
  end

  def background?
    channel == "background"
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

  # Find an existing email conversation by thread key and references list.
  # Searches external_thread_key column and email_references_chain metadata.
  # Falls back to UUID-based fuzzy matching to handle Message-ID domain mismatches
  # (e.g., outbound stored as @withstuart.com but replies reference @mtasv.net).
  def self.find_by_email_thread(workspace:, agent:, thread_key:, all_references: [])
    scope = where(workspace: workspace, agent: agent, channel: "email")

    # Exact match on thread key first
    exact = scope.where(external_thread_key: thread_key).first
    return exact if exact

    # Check if any of the incoming references match a stored thread key
    if all_references.any?
      by_ref = scope.where(external_thread_key: all_references).first
      return by_ref if by_ref
    end

    # Check if any incoming references appear in stored reference chains
    if all_references.any?
      all_references.each do |ref|
        by_chain = scope.where("metadata->'email_references_chain' @> ?", [ref].to_json).first
        return by_chain if by_chain
      end
    end

    # UUID-based fuzzy match on thread key (handles domain mismatches)
    uuid = thread_key.to_s.delete("<>").split("@").first
    return nil if uuid.blank? || uuid.length < 8

    scope.where("external_thread_key LIKE ?", "%#{sanitize_sql_like(uuid)}%").first
  end

  # Merge new participants into the conversation's participant list.
  def merge_email_participants!(new_participants)
    existing = metadata&.dig("email_participants") || []
    existing_emails = existing.map { |p| p["email"] }

    new_participants.each do |p|
      unless existing_emails.include?(p["email"])
        existing << p
        existing_emails << p["email"]
      end
    end

    update!(metadata: (metadata || {}).merge("email_participants" => existing))
  end
end
