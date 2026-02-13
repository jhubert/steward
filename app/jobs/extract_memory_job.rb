class ExtractMemoryJob < ApplicationJob
  queue_as :low_priority

  discard_on ActiveRecord::RecordNotFound

  def perform(conversation_id)
    conversation = Conversation.find(conversation_id)
    Current.workspace = conversation.workspace

    state = conversation.ensure_state!
    unextracted = state.unextracted_messages.limit(50)
    return if unextracted.empty?

    context = dedup_context(conversation)
    extractor = Memory::Extractor.new(agent: conversation.agent)
    items = extractor.call(messages: unextracted, context: context)

    last_message = unextracted.last

    items.each do |item|
      record = MemoryItem.create!(
        workspace: conversation.workspace,
        user: conversation.user,
        conversation: conversation,
        category: item[:category],
        content: item[:content],
        metadata: { source_message_range: [unextracted.first.id, last_message.id] }
      )
      GenerateEmbeddingJob.perform_later(record.id)
    end

    # Always advance pointer — even if nothing extracted — to avoid re-processing
    state.advance_extraction!(last_message.id)

    Rails.logger.info(
      "[Memory] Conversation #{conversation.id}: extracted #{items.size} items from #{unextracted.size} messages"
    )
  end

  private

  def dedup_context(conversation)
    agent = conversation.agent

    if agent.principal_mode?
      principal_user_ids = agent.agent_principals.pluck(:user_id)
      MemoryItem.where(user_id: principal_user_ids).order(created_at: :desc).limit(50)
    else
      MemoryItem.where(user: conversation.user).order(created_at: :desc).limit(50)
    end
  end
end
