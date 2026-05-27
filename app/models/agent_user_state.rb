class AgentUserState < ApplicationRecord
  include WorkspaceScoped

  belongs_to :user
  belongs_to :agent

  # Finds or creates the per-(user, agent) relationship state.
  # This is the single durable container for cross-channel context the agent
  # has built up about a specific user — independent of any one Conversation.
  def self.for(user:, agent:)
    Current.workspace ||= user.workspace
    unscoped.find_or_create_by!(workspace: user.workspace, user: user, agent: agent)
  end

  def touch_interaction!(message)
    return if last_interaction_at.present? && message.created_at <= last_interaction_at
    update!(last_interaction_at: message.created_at)
  end

  def unsummarized_messages
    Message.where(user_id: user_id, agent_id: agent_id)
           .where('id > ?', summarized_through_message_id || 0)
           .order(:id)
  end
end
