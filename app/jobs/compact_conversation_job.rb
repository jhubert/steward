class CompactConversationJob < ApplicationJob
  queue_as :low_priority

  def perform(conversation_id)
    conversation = Conversation.find(conversation_id)
    Current.workspace = conversation.workspace

    state = conversation.ensure_state!
    unsummarized = state.unsummarized_messages.limit(50)

    return if unsummarized.count < Conversation::COMPACTION_THRESHOLD

    summarizer = Compaction::Summarizer.new(agent: conversation.agent)
    new_summary = summarizer.call(
      existing_summary: state.summary,
      messages: unsummarized
    )

    state.advance_summary!(new_summary, unsummarized.last.id)

    Rails.logger.info(
      "[Compaction] Conversation #{conversation.id}: summarized through message #{unsummarized.last.id}"
    )
  end
end
