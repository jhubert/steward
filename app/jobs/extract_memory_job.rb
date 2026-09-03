class ExtractMemoryJob < ApplicationJob
  queue_as :low_priority

  discard_on ActiveRecord::RecordNotFound

  # Separate namespace from ProcessMessageJob's conversation lock (which uses
  # namespace 1) — extraction shouldn't block message processing or vice versa.
  LOCK_NAMESPACE = 2

  def perform(conversation_id)
    conversation = Conversation.find(conversation_id)
    Current.workspace = conversation.workspace

    # The sibling sweep in ProcessMessageJob can enqueue this multiple times
    # for the same conversation before the first run advances the extraction
    # pointer. Without serializing, concurrent runs see the same unextracted
    # messages and double-extract them into duplicate MemoryItem records.
    unless acquire_conversation_lock(conversation)
      self.class.set(wait: 5.seconds).perform_later(conversation_id)
      return
    end

    begin
      state = conversation.ensure_state!
      unextracted = state.unextracted_messages.limit(50)
      return if unextracted.empty?

      context = dedup_context(conversation)
      supersedable_ids = context.map(&:id).to_set

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
          subject_scope: item[:scope] || 'principal',
          expires_at: MemoryItem.expiry_for(item[:durability]),
          visibility: item[:core] ? MemoryItem::SHARED_VISIBILITY : MemoryItem::AGENT_VISIBILITY,
          metadata: {
            source_message_range: [unextracted.first.id, last_message.id],
            durability: item[:durability]
          }
        )
        GenerateEmbeddingJob.perform_later(record.id)

        retire_superseded(item[:supersedes], record, supersedable_ids)

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
    ensure
      release_conversation_lock(conversation)
    end
  end

  private

  def acquire_conversation_lock(conversation)
    result = ActiveRecord::Base.connection.select_value(
      "SELECT pg_try_advisory_lock(#{LOCK_NAMESPACE}, #{conversation.id})"
    )
    result == true
  end

  def release_conversation_lock(conversation)
    ActiveRecord::Base.connection.execute(
      "SELECT pg_advisory_unlock(#{LOCK_NAMESPACE}, #{conversation.id})"
    )
  end

  # Retire a fact the new one replaces. The extractor proposes the id; we only
  # act on it if that id was in the context we actually showed it, which keeps
  # supersession inside what this agent is allowed to see and makes a
  # hallucinated id a no-op rather than a cross-tenant write.
  def retire_superseded(old_id, replacement, allowed_ids)
    return if old_id.blank?
    return unless allowed_ids.include?(old_id)

    old = MemoryItem.current.find_by(id: old_id)
    return if old.nil?
    return if old.id == replacement.id

    old.supersede!(by: replacement)
    Rails.logger.info(
      "[Memory] Superseded item #{old.id} with #{replacement.id}: #{replacement.content.truncate(80)}"
    )
  rescue StandardError => e
    # Never let a bad supersession hint lose the new memory we just wrote.
    Rails.logger.warn("[Memory] Supersession of #{old_id} failed: #{e.message}")
  end

  # Dedup context is scoped per-principal — extracting Alice's conversation
  # only checks against Alice's existing memories. Previously this pooled
  # all principals' memories together, which coupled them in a non-obvious
  # way (e.g. Bob mentioning a fact Alice already stated wouldn't get
  # extracted as Bob's, only Alice would have it).
  # Now also includes the shared principal core, so an agent doesn't re-extract
  # a fact another agent already promoted. This is the point of the core: one
  # copy of "who this person is", not one per agent.
  def dedup_context(conversation)
    MemoryItem.current
              .where(user: conversation.user)
              .readable_by_agent(conversation.agent)
              .order(created_at: :desc)
              .limit(50)
  end
end
