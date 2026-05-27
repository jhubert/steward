class RelationshipSummaryJob < ApplicationJob
  queue_as :low_priority

  discard_on ActiveRecord::RecordNotFound

  # Refreshes AgentUserState#summary for a given (user, agent) pair.
  # Re-runs the LLM only when there's new activity since the last refresh.
  def perform(agent_user_state_id)
    state = AgentUserState.unscoped.find(agent_user_state_id)
    Current.workspace = state.workspace

    return if state.last_interaction_at.blank?
    return if state.last_summarized_at.present? &&
              state.last_summarized_at >= state.last_interaction_at

    summary = Memory::RelationshipSummarizer.new(state).call
    return if summary.blank?

    state.update!(summary: summary, last_summarized_at: Time.current)

    Rails.logger.info(
      "[RelationshipSummary] Updated AgentUserState #{state.id} " \
      "(user=#{state.user_id} agent=#{state.agent_id})"
    )
  end
end
