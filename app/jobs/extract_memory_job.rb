class ExtractMemoryJob < ApplicationJob
  queue_as :low_priority

  discard_on ActiveRecord::RecordNotFound

  def perform(conversation_id, user_message_id, assistant_message_id)
    conversation = Conversation.find(conversation_id)
    Current.workspace = conversation.workspace

    user_message = conversation.messages.find(user_message_id)
    assistant_message = conversation.messages.find(assistant_message_id)

    # Load recent memory items for dedup context
    context = dedup_context(conversation)

    extractor = Memory::Extractor.new(agent: conversation.agent)
    items = extractor.call(
      user_message: user_message.content,
      assistant_reply: assistant_message.content,
      context: context
    )

    return if items.empty?

    items.each do |item|
      MemoryItem.create!(
        workspace: conversation.workspace,
        user: conversation.user,
        conversation: conversation,
        category: item[:category],
        content: item[:content],
        metadata: {
          source_user_message_id: user_message_id,
          source_assistant_message_id: assistant_message_id
        }
      )
    end

    Rails.logger.info(
      "[Memory] Conversation #{conversation.id}: extracted #{items.size} items"
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
