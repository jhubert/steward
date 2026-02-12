class ProcessMessageJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(message_id)
    message = Message.find(message_id)
    conversation = message.conversation

    # Set workspace context for scoped queries
    Current.workspace = conversation.workspace

    # Single-writer lock on the conversation
    conversation.with_lock do
      # Build prompt from memory layers
      assembler = Prompt::Assembler.new(conversation)
      messages = assembler.call

      # Append the new user message
      messages << { role: 'user', content: message.content }

      # Show typing indicator
      adapter = adapter_for(conversation)
      adapter.send_typing(conversation) if adapter.respond_to?(:send_typing)

      # Call the LLM
      started_at = Time.current
      response = ANTHROPIC_CLIENT.messages.create(
        model: conversation.agent.model,
        max_tokens: conversation.agent.token_budgets['response'],
        system: messages.first[:content],
        messages: messages[1..]
      )
      latency_ms = ((Time.current - started_at) * 1000).round

      reply_text = response.content.first.text

      # Store the assistant reply
      reply = conversation.messages.create!(
        workspace: conversation.workspace,
        user: conversation.user,
        role: 'assistant',
        content: reply_text,
        token_count: response.usage.output_tokens,
        metadata: {
          model: response.model,
          input_tokens: response.usage.input_tokens,
          latency_ms: latency_ms
        }
      )

      # Send reply via the channel adapter
      adapter.send_reply(conversation, reply)

      # Check if compaction is needed
      CompactConversationJob.perform_later(conversation.id) if conversation.needs_compaction?

      # Extract memory items from the exchange
      ExtractMemoryJob.perform_later(conversation.id, message.id, reply.id)
    end
  end

  private

  def adapter_for(conversation)
    case conversation.channel
    when 'telegram'
      Adapters::Telegram.new(bot_token: conversation.agent.telegram_bot_token)
    else
      raise "Unknown channel: #{conversation.channel}"
    end
  end
end
