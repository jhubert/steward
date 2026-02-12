class ProcessMessageJob < ApplicationJob
  queue_as :default

  MAX_TOOL_ROUNDS = 10

  retry_on Adapters::DeliveryError, wait: 5.seconds, attempts: 3 do |job, error|
    notify_failure(job.arguments.first, error)
  end

  retry_on StandardError, wait: :polynomially_longer, attempts: 3 do |job, error|
    notify_failure(job.arguments.first, error)
  end

  def perform(message_id)
    message = Message.find(message_id)
    conversation = message.conversation

    # Set workspace context for scoped queries
    Current.workspace = conversation.workspace

    reply = nil

    # Single-writer lock: generate LLM reply and persist it
    conversation.with_lock do
      agent = conversation.agent
      adapter = adapter_for(conversation)

      # Show typing indicator (best-effort, don't fail the job)
      adapter.send_typing(conversation) rescue nil

      # Idempotency: if we already generated a reply for this message, skip LLM work
      existing_reply = conversation.messages.where(role: 'assistant')
                                            .find_by("metadata->>'source_message_id' = ?", message.id.to_s)
      if existing_reply
        reply = existing_reply
      else
        reply = generate_reply(message, conversation, agent, adapter)
      end
    end

    # Delivery happens outside the transaction — if this fails, the reply
    # is already persisted and retry will skip the LLM call above
    adapter = adapter_for(conversation)
    adapter.send_reply(conversation, reply)

    # Post-delivery jobs (best-effort, failures here don't affect the user)
    CompactConversationJob.perform_later(conversation.id) if conversation.needs_compaction?
    ExtractMemoryJob.perform_later(conversation.id, message.id, reply.id)
  end

  private

  def generate_reply(message, conversation, agent, adapter)
    # Build prompt from memory layers
    assembler = Prompt::Assembler.new(conversation)
    messages = assembler.call

    # Append the new user message
    messages << { role: 'user', content: message.content }

    # Get tool definitions (nil if agent has no tools)
    tool_definitions = Tools::DefinitionBuilder.new(agent: agent).call

    # Tool use loop
    total_input_tokens = 0
    total_output_tokens = 0
    tool_call_summaries = []
    reply_text = nil
    response_model = nil
    started_at = Time.current
    rounds = 0

    loop do
      api_params = {
        model: agent.model,
        max_tokens: agent.token_budgets['response'],
        system: messages.first[:content],
        messages: messages[1..]
      }
      api_params[:tools] = tool_definitions if tool_definitions

      response = ANTHROPIC_CLIENT.messages.create(**api_params)
      response_model = response.model
      total_input_tokens += response.usage.input_tokens
      total_output_tokens += response.usage.output_tokens

      if response.stop_reason.to_s == 'tool_use'
        rounds += 1

        if rounds >= MAX_TOOL_ROUNDS
          reply_text = extract_text(response.content)
          reply_text = "(Tool use limit reached)" if reply_text.blank?
          break
        end

        messages << { role: 'assistant', content: serialize_content(response.content) }

        tool_results = response.content.filter_map do |block|
          next unless block.type.to_s == 'tool_use'

          result = execute_tool(block, agent, conversation)
          tool_call_summaries << result[:summary]

          { type: 'tool_result', tool_use_id: block.id, content: result[:content] }
        end

        messages << { role: 'user', content: tool_results }

        # Show typing while processing continues
        adapter.send_typing(conversation) rescue nil
      else
        reply_text = extract_text(response.content)
        break
      end
    end

    latency_ms = ((Time.current - started_at) * 1000).round

    reply_metadata = {
      model: response_model,
      input_tokens: total_input_tokens,
      output_tokens: total_output_tokens,
      latency_ms: latency_ms,
      source_message_id: message.id
    }
    reply_metadata[:tool_calls] = tool_call_summaries if tool_call_summaries.any?

    conversation.messages.create!(
      workspace: conversation.workspace,
      user: conversation.user,
      role: 'assistant',
      content: reply_text.presence || "(No text response)",
      token_count: total_output_tokens,
      metadata: reply_metadata
    )
  end

  def self.notify_failure(message_id, error)
    message = Message.find_by(id: message_id)
    return unless message

    conversation = message.conversation
    Current.workspace = conversation.workspace

    error_text = "Sorry, I ran into a problem and couldn't process your message. (#{error.class.name}: #{error.message.truncate(200)})"

    conversation.messages.create!(
      workspace: conversation.workspace,
      user: conversation.user,
      role: 'assistant',
      content: error_text,
      metadata: { error: true, original_error: error.class.name }
    )

    adapter = new.send(:adapter_for, conversation)
    adapter.send_reply(conversation, conversation.messages.last)
  rescue => e
    Rails.logger.error("[ProcessMessageJob] Failed to send error notification: #{e.message}")
  end

  def adapter_for(conversation)
    case conversation.channel
    when 'telegram'
      Adapters::Telegram.new(bot_token: conversation.agent.telegram_bot_token)
    else
      raise "Unknown channel: #{conversation.channel}"
    end
  end

  def execute_tool(tool_use_block, agent, conversation)
    agent_tool = agent.enabled_tools.find_by(name: tool_use_block.name)

    unless agent_tool
      return {
        content: "Error: Unknown tool '#{tool_use_block.name}'",
        summary: { name: tool_use_block.name, exit_code: nil, error: "unknown tool" }
      }
    end

    input = tool_use_block.input.is_a?(Hash) ? tool_use_block.input : {}
    executor = Tools::Executor.new(agent_tool: agent_tool)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = executor.call(input)
    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

    ToolExecution.create!(
      workspace: conversation.workspace,
      agent_tool: agent_tool,
      conversation: conversation,
      tool_use_id: tool_use_block.id,
      input: input,
      output: result.stdout,
      error: result.stderr,
      exit_code: result.exit_code,
      timed_out: result.timed_out,
      duration_ms: duration_ms
    )

    content = if result.timed_out
      "Error: #{result.stderr}"
    elsif result.exit_code != 0
      "Exit code: #{result.exit_code}\nStderr: #{result.stderr}\nStdout: #{result.stdout}"
    else
      result.stdout
    end

    {
      content: content,
      summary: { name: agent_tool.name, exit_code: result.exit_code, duration_ms: duration_ms, timed_out: result.timed_out }
    }
  end

  def extract_text(content_blocks)
    content_blocks.filter_map { |b| b.text if b.respond_to?(:text) }.join("\n")
  end

  def serialize_content(content_blocks)
    content_blocks.map do |block|
      if block.type.to_s == 'text'
        { type: 'text', text: block.text }
      elsif block.type.to_s == 'tool_use'
        { type: 'tool_use', id: block.id, name: block.name, input: block.input }
      end
    end.compact
  end
end
