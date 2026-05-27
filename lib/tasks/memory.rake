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
end
