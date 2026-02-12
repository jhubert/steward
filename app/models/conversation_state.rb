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

  MAX_TOOL_LOG_ENTRIES = 10

  def append_tool_log!(entry)
    new_log = (tool_log || []) + [entry]
    update!(tool_log: new_log.last(MAX_TOOL_LOG_ENTRIES))
  end
end
