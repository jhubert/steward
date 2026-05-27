class CompactConversationJob < ApplicationJob
  queue_as :low_priority

  def perform(conversation_id)
    conversation = Conversation.find(conversation_id)
    Current.workspace = conversation.workspace

    state = conversation.ensure_state!
    unsummarized = state.unsummarized_messages.limit(50)

    return if unsummarized.empty?
    triggered_by_idle = conversation.stale_for_compaction?
    return if unsummarized.count < Conversation::COMPACTION_THRESHOLD && !triggered_by_idle

    first_id = unsummarized.first.id
    last_id  = unsummarized.last.id

    summarizer = Compaction::Summarizer.new(agent: conversation.agent)
    new_summary = summarizer.call(
      existing_summary: state.summary,
      messages: unsummarized
    )

    state.advance_summary!(new_summary, last_id)

    Rails.logger.info(
      "[Compaction] Conversation #{conversation.id}: summarized through message #{last_id}"
    )

    # When an idle compaction flushes a quiet conversation, that span is a
    # natural "completed session" — build an episode so it's searchable
    # going forward.
    BuildEpisodeJob.perform_later(conversation.id, first_id, last_id) if triggered_by_idle

    ExtractMemoryJob.perform_later(conversation_id) if conversation.needs_extraction?
  end
end
