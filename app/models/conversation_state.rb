class ConversationState < ApplicationRecord
  include WorkspaceScoped

  belongs_to :conversation
  belongs_to :user

  def unsummarized_messages
    conversation.messages.unsummarized_since(summarized_through_message_id)
  end

  def advance_summary!(new_summary, through_message_id)
    update!(
      summary: new_summary,
      summarized_through_message_id: through_message_id
    )
  end
end
