namespace :memory do
  desc "Backfill agent_user_states + flush stale compactions/extractions (Phase 1)"
  task backfill_phase1: :environment do
    require "active_support/core_ext/integer/time"

    puts "[memory:backfill_phase1] Starting at #{Time.current}"

    # 1) Create AgentUserState for every (user, agent) pair that has ever exchanged
    #    a message. last_interaction_at = latest message time across all channels.
    pairs = Message.unscoped
                   .group(:workspace_id, :user_id, :agent_id)
                   .maximum(:created_at)

    created = 0
    skipped = 0

    pairs.each do |(workspace_id, user_id, agent_id), last_at|
      next if workspace_id.nil? || user_id.nil? || agent_id.nil?

      state = AgentUserState.unscoped.find_or_initialize_by(
        workspace_id: workspace_id, user_id: user_id, agent_id: agent_id
      )
      if state.new_record?
        state.last_interaction_at = last_at
        state.save!
        created += 1
      elsif state.last_interaction_at.nil? || state.last_interaction_at < last_at
        state.update!(last_interaction_at: last_at)
        skipped += 1
      else
        skipped += 1
      end
    end

    puts "[memory:backfill_phase1] AgentUserState: created=#{created} existing=#{skipped}"

    # 2) Enqueue compact + extract for any conversation that has gone stale —
    #    i.e. has unsummarized/unextracted content but no recent activity to
    #    naturally trigger compaction.
    enqueued_compact = 0
    enqueued_extract = 0

    Conversation.unscoped.find_each do |conv|
      Current.workspace = conv.workspace
      if conv.stale_for_compaction?
        CompactConversationJob.perform_later(conv.id)
        enqueued_compact += 1
      end
      if conv.stale_for_extraction?
        ExtractMemoryJob.perform_later(conv.id)
        enqueued_extract += 1
      end
    end

    puts "[memory:backfill_phase1] Enqueued compact=#{enqueued_compact} extract=#{enqueued_extract}"
    puts "[memory:backfill_phase1] Done at #{Time.current}"
  end

  desc "Backfill episodes and enqueue relationship summaries (Phase 2)"
  task backfill_phase2: :environment do
    puts "[memory:backfill_phase2] Starting at #{Time.current}"

    # 1) For every conversation that has been summarized (state.summary
    #    present, summarized_through_message_id set), create a single
    #    backfill episode covering its summarized message range — best-effort
    #    one-shot. Future episodes are produced naturally by session breaks
    #    and idle compactions.
    built = 0
    skipped = 0
    Conversation.unscoped.find_each do |conv|
      Current.workspace = conv.workspace
      state = conv.state
      next unless state&.summary.present? && state.summarized_through_message_id

      msgs = conv.messages.where('id <= ?', state.summarized_through_message_id).order(:id)
      next if msgs.empty?

      first_id = msgs.first.id
      last_id  = msgs.last.id

      if Episode.unscoped.where(conversation_id: conv.id, first_message_id: first_id, last_message_id: last_id).exists?
        skipped += 1
        next
      end

      BuildEpisodeJob.perform_later(conv.id, first_id, last_id)
      built += 1
    end

    puts "[memory:backfill_phase2] Episodes: enqueued=#{built} already_present=#{skipped}"

    # 2) Enqueue RelationshipSummaryJob for every AgentUserState that has
    #    activity but no summary yet (or a stale one).
    enqueued = 0
    AgentUserState.unscoped.find_each do |state|
      Current.workspace = state.workspace
      next if state.last_interaction_at.blank?
      next if state.last_summarized_at.present? &&
              state.last_summarized_at >= state.last_interaction_at

      RelationshipSummaryJob.perform_later(state.id)
      enqueued += 1
    end

    puts "[memory:backfill_phase2] RelationshipSummaryJob enqueued=#{enqueued}"
    puts "[memory:backfill_phase2] Done at #{Time.current}"
  end
end
