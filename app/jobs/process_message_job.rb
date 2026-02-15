class ProcessMessageJob < ApplicationJob
  queue_as :default

  MAX_TOOL_ROUNDS = 50

  retry_on "Adapters::DeliveryError", wait: 5.seconds, attempts: 3 do |job, error|
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

      # Session break: compact old messages if there's a long gap
      if conversation.session_break_needed?(message)
        conversation.compact_for_session_break!(message)
      end

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
    ExtractMemoryJob.perform_later(conversation.id) if conversation.needs_extraction?
    GenerateTitleJob.perform_later(conversation.id) if conversation.title.blank?
  end

  private

  def generate_reply(message, conversation, agent, adapter)
    # Build prompt from memory layers
    assembler = Prompt::Assembler.new(conversation, incoming_message: message.content)
    messages = assembler.call

    # Append the new user message
    messages << { role: 'user', content: message.content }

    # Get tool definitions (nil if agent has no tools)
    tool_definitions = Tools::DefinitionBuilder.new(agent: agent).call

    # Tool use loop
    total_input_tokens = 0
    total_output_tokens = 0
    tool_call_summaries = []
    tool_log_rounds = []
    reply_text = nil
    response_model = nil
    started_at = Time.current
    rounds = 0
    max_rounds = [agent.max_tool_rounds, MAX_TOOL_ROUNDS].min

    loop do
      api_params = {
        model: agent.model,
        max_tokens: agent.token_budgets['response'],
        system: messages.first[:content],
        messages: messages[1..]
      }
      api_params[:tools] = tool_definitions if tool_definitions

      response = Rails.configuration.anthropic_client.messages.create(**api_params)
      response_model = response.model
      total_input_tokens += response.usage.input_tokens
      total_output_tokens += response.usage.output_tokens

      if response.stop_reason.to_s == 'tool_use'
        rounds += 1

        if rounds >= max_rounds
          # Give the LLM one final call without tools to produce a useful reply
          messages << { role: 'assistant', content: serialize_content(response.content) }
          # Provide dummy tool results so the API accepts the messages
          dummy_results = response.content.filter_map do |block|
            next unless block.type.to_s == 'tool_use'
            { type: 'tool_result', tool_use_id: block.id, content: '(not executed — tool use limit reached)' }
          end
          messages << { role: 'user', content: dummy_results }
          messages << { role: 'user', content: 'You have reached the tool use limit for this message. Do NOT call any more tools. Instead, reply to me directly: summarize what you accomplished, what went wrong or is still incomplete, and suggest what I can do next.' }

          final_response = Rails.configuration.anthropic_client.messages.create(
            model: agent.model,
            max_tokens: agent.token_budgets['response'],
            system: messages.first[:content],
            messages: messages[1..]
          )
          total_input_tokens += final_response.usage.input_tokens
          total_output_tokens += final_response.usage.output_tokens
          reply_text = extract_text(final_response.content)
          reply_text = "(Tool use limit reached)" if reply_text.blank?
          break
        end

        messages << { role: 'assistant', content: serialize_content(response.content) }

        tool_results = response.content.filter_map do |block|
          next unless block.type.to_s == 'tool_use'

          result = execute_tool(block, agent, conversation)
          tool_call_summaries << result[:summary]
          tool_log_rounds << result[:log_entry]

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

    # Persist tool activity log for cross-message memory
    if tool_log_rounds.any?
      state = conversation.ensure_state!
      state.append_tool_log!({
        "timestamp" => Time.current.iso8601,
        "rounds" => tool_log_rounds
      })
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
    input = tool_use_block.input.is_a?(Hash) ? tool_use_block.input.transform_keys(&:to_s) : {}

    # Handle virtual (built-in) tools
    virtual_result = execute_virtual_tool(tool_use_block.name, input, conversation)
    return virtual_result if virtual_result

    agent_tool = agent.enabled_tools.find_by(name: tool_use_block.name)

    unless agent_tool
      return {
        content: "Error: Unknown tool '#{tool_use_block.name}'",
        summary: { name: tool_use_block.name, exit_code: nil, error: "unknown tool" },
        log_entry: { "tool" => tool_use_block.name, "error" => "unknown tool" }
      }
    end

    executor = Tools::Executor.new(agent_tool: agent_tool)
    extra_env = build_principal_env(agent, conversation)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = executor.call(input, extra_env: extra_env)
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
      summary: { name: agent_tool.name, exit_code: result.exit_code, duration_ms: duration_ms, timed_out: result.timed_out },
      log_entry: { "tool" => agent_tool.name, "input" => input.to_s.truncate(200), "output" => content.to_s.truncate(500), "exit_code" => result.exit_code }
    }
  end

  def execute_virtual_tool(name, input, conversation)
    case name
    when "save_note"
      state = conversation.ensure_state!
      note = input["content"].to_s
      new_scratchpad = state.scratchpad.to_s
      new_scratchpad += "\n" if new_scratchpad.present?
      new_scratchpad += "[#{Time.current.strftime('%Y-%m-%d %H:%M')}] #{note}"
      state.update!(scratchpad: new_scratchpad.last(10_000))
      virtual_result("save_note", "Note saved to scratchpad.", input: note.truncate(200))
    when "read_notes"
      state = conversation.ensure_state!
      content = state.scratchpad.present? ? state.scratchpad : "(Scratchpad is empty)"
      virtual_result("read_notes", content)
    when "google_setup"
      execute_google_setup(input, conversation)
    when "download_file"
      execute_download_file(input, conversation)
    when "schedule_task"
      execute_schedule_task(input, conversation)
    when "list_scheduled_tasks"
      execute_list_scheduled_tasks(conversation)
    when "cancel_scheduled_task"
      execute_cancel_scheduled_task(input, conversation)
    end
  end

  def execute_google_setup(input, conversation)
    action = input["action"].to_s
    agent = conversation.agent
    principal = agent.agent_principals.find_by(user: conversation.user)

    unless principal
      return virtual_result("google_setup", "Error: This user is not a principal of this agent. Google setup requires principal access.")
    end

    authenticator = Gog::Authenticator.new(agent_principal: principal)

    case action
    when "check"
      if authenticator.configured?
        virtual_result("google_setup", "Google account is configured for this user. Keyring credentials are present.")
      else
        virtual_result("google_setup", "Google account is NOT configured for this user. Use the 'start' action to begin setup, or 'generate_link' to send a web setup URL.")
      end
    when "start"
      email = input["email"].to_s.strip
      if email.blank?
        return virtual_result("google_setup", "Error: 'email' parameter is required for the 'start' action.")
      end

      result = authenticator.start_auth(email)
      if result.success
        virtual_result("google_setup", "Auth step 1 complete. Send the user this URL to authorize:\n\n#{result.output}\n\nInstructions: Open this URL, sign in with Google, grant access, then copy the full URL from the browser address bar after the redirect (it will start with http://localhost:1/) and paste it back here.", input: email)
      else
        virtual_result("google_setup", "Error starting auth: #{result.error}", input: email)
      end
    when "complete"
      email = input["email"].to_s.strip
      auth_url = input["auth_url"].to_s.strip
      if email.blank? || auth_url.blank?
        return virtual_result("google_setup", "Error: Both 'email' and 'auth_url' parameters are required for the 'complete' action.")
      end

      result = authenticator.complete_auth(email, auth_url)
      if result.success
        virtual_result("google_setup", "Google account successfully connected for #{email}! The user can now use Google Workspace features.", input: email)
      else
        virtual_result("google_setup", "Error completing auth: #{result.error}", input: email)
      end
    when "generate_link"
      token = Gog::SetupToken.generate(user: conversation.user, agent: agent, workspace: conversation.workspace)
      url = "https://steward.boardwise.co/setup/google/#{token}"
      virtual_result("google_setup", "Web setup URL (valid for 1 hour):\n#{url}\n\nSend this link to the user. They can complete Google account setup through the web interface.")
    else
      virtual_result("google_setup", "Error: Unknown action '#{action}'. Valid actions: check, start, complete, generate_link.")
    end
  end

  def execute_schedule_task(input, conversation)
    description = input["description"].to_s.strip
    run_at_str = input["run_at"].to_s.strip
    interval = input["interval"].to_s.strip.presence || "once"
    custom_seconds = input["interval_seconds"]

    if description.blank? || run_at_str.blank?
      return virtual_result("schedule_task", "Error: 'description' and 'run_at' are required.")
    end

    begin
      run_at = Time.parse(run_at_str)
    rescue ArgumentError
      return virtual_result("schedule_task", "Error: Invalid run_at datetime '#{run_at_str}'. Use ISO 8601 format.")
    end

    interval_seconds = case interval
    when "once" then nil
    when "hourly" then 3600
    when "daily" then 86_400
    when "weekly" then 604_800
    when "custom"
      custom_seconds.to_i > 0 ? custom_seconds.to_i : nil
    end

    if interval == "custom" && interval_seconds.nil?
      return virtual_result("schedule_task", "Error: 'interval_seconds' is required for custom intervals and must be positive.")
    end

    task = ScheduledTask.create!(
      workspace: conversation.workspace,
      agent: conversation.agent,
      conversation: conversation,
      description: description,
      next_run_at: run_at,
      interval_seconds: interval_seconds
    )

    schedule_desc = interval_seconds ? "recurring (#{task.interval_description})" : "one-time"
    virtual_result("schedule_task", "Task scheduled (ID: #{task.id}).\nDescription: #{description}\nNext run: #{run_at.iso8601}\nType: #{schedule_desc}", input: description.truncate(200))
  end

  def execute_list_scheduled_tasks(conversation)
    tasks = conversation.scheduled_tasks.order(:next_run_at)

    if tasks.empty?
      return virtual_result("list_scheduled_tasks", "No scheduled tasks for this conversation.")
    end

    lines = tasks.map do |t|
      status = t.enabled? ? "active" : "disabled"
      "- [#{t.id}] #{t.description} | Next: #{t.next_run_at&.iso8601 || 'N/A'} | #{t.interval_description} | #{status}"
    end

    virtual_result("list_scheduled_tasks", "Scheduled tasks:\n#{lines.join("\n")}")
  end

  def execute_cancel_scheduled_task(input, conversation)
    task_id = input["task_id"]

    unless task_id
      return virtual_result("cancel_scheduled_task", "Error: 'task_id' is required.")
    end

    task = conversation.scheduled_tasks.find_by(id: task_id)

    unless task
      return virtual_result("cancel_scheduled_task", "Error: Task ##{task_id} not found in this conversation.")
    end

    task.cancel!
    virtual_result("cancel_scheduled_task", "Task ##{task.id} cancelled: #{task.description}", input: task_id.to_s)
  end

  def execute_download_file(input, conversation)
    url = input["url"].to_s.strip
    filename = input["filename"]&.strip.presence

    if url.blank?
      return virtual_result("download_file", "Error: 'url' parameter is required.")
    end

    downloader = Tools::FileDownloader.new(
      agent_id: conversation.agent_id,
      conversation_id: conversation.id
    )
    result = downloader.call(url, filename: filename)

    if result.success
      virtual_result("download_file", "File downloaded successfully.\nPath: #{result.path}\nSize: #{result.size} bytes", input: url.truncate(200))
    else
      virtual_result("download_file", "Download failed: #{result.error}", input: url.truncate(200))
    end
  end

  def virtual_result(tool_name, content, input: nil)
    log_input = input ? { "input" => input.to_s.truncate(200) } : {}
    {
      content: content,
      summary: { name: tool_name },
      log_entry: { "tool" => tool_name, "output" => content.to_s.truncate(500) }.merge(log_input)
    }
  end

  def build_principal_env(agent, conversation)
    principal = agent.agent_principals.find_by(user: conversation.user)
    return {} unless principal&.credentials&.key?("gog_keyring_password")

    user_gog_dir = Rails.root.join("data", "gog", conversation.user.id.to_s).to_s
    {
      "XDG_CONFIG_HOME" => user_gog_dir,
      "GOG_KEYRING_PASSWORD" => principal.credentials["gog_keyring_password"],
      "GOG_KEYRING_BACKEND" => "file"
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
