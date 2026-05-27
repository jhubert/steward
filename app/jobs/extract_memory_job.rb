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

    outgoing_commitments_to_add = []

    items.each do |item|
      record = MemoryItem.create!(
        workspace: conversation.workspace,
        user: conversation.user,
        agent: conversation.agent,
        conversation: conversation,
        category: item[:category],
        content: item[:content],
        observed_at: item[:observed_at],
        metadata: { source_message_range: [unextracted.first.id, last_message.id] }
      )
      GenerateEmbeddingJob.perform_later(record.id)

      # Lift agent-side commitments into the relationship-level state so
      # they surface at the top of every future prompt for this user until
      # the agent marks them done.
      if item[:category] == 'commitment' && item[:subject] == 'agent'
        outgoing_commitments_to_add << {
          "text" => item[:content],
          "made_at" => Time.current.iso8601,
          "memory_item_id" => record.id,
          "source_conversation_id" => conversation.id
        }
      end
    end

    if outgoing_commitments_to_add.any?
      relationship = AgentUserState.for(user: conversation.user, agent: conversation.agent)
      existing = Array(relationship.outgoing_commitments)
      relationship.update!(outgoing_commitments: existing + outgoing_commitments_to_add)
    end

    # Always advance pointer — even if nothing extracted — to avoid re-processing
    state.advance_extraction!(last_message.id)

    Rails.logger.info(
      "[Memory] Conversation #{conversation.id}: extracted #{items.size} items from #{unextracted.size} messages"
    )
  end

  private

  # Dedup context is scoped per-principal — extracting Alice's conversation
  # only checks against Alice's existing memories. Previously this pooled
  # all principals' memories together, which coupled them in a non-obvious
  # way (e.g. Bob mentioning a fact Alice already stated wouldn't get
  # extracted as Bob's, only Alice would have it).
  def dedup_context(conversation)
    MemoryItem.current
              .where(user: conversation.user, agent: conversation.agent)
              .order(created_at: :desc)
              .limit(50)
  end
end
