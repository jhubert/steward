class RunScheduledTaskJob < ApplicationJob
  queue_as :default

  def perform(scheduled_task_id)
    task = ScheduledTask.unscoped.find_by(id: scheduled_task_id)
    return unless task
    return unless task.enabled?
    return unless task.next_run_at <= Time.current

    Current.workspace = task.workspace

    task.advance!

    if task.direct_execution?
      run_direct(task)
    else
      task.agent.trigger(
        user: task.user,
        content: "[Scheduled Task] #{task.description}"
      )
    end
  end

  private

  def run_direct(task)
    agent_tool = task.agent_tool
    executor = Tools::Executor.new(agent_tool: agent_tool)
    extra_env = task.agent.principal_env_for(task.user).merge(
      "STEWARD_USER_ID" => task.user_id.to_s
    )

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = executor.call(task.tool_input, extra_env: extra_env)
    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

    ToolExecution.create!(
      workspace: task.workspace,
      agent_tool: agent_tool,
      conversation: nil,
      tool_use_id: "scheduled_task_#{task.id}",
      input: task.tool_input,
      output: result.stdout,
      error: result.stderr,
      exit_code: result.exit_code,
      timed_out: result.timed_out,
      duration_ms: duration_ms
    )

    failed = result.timed_out || (result.exit_code && result.exit_code != 0)

    if failed
      task.record_failure!
      if task.failure_threshold_reached?
        notify_failure_via_telegram(task, result)
        return
      end
    else
      task.record_success!
    end

    # Trigger LLM if there's output to act on, or if the tool failed
    if result.stdout.present? || failed
      content = build_trigger_content(task, result)
      task.agent.trigger(user: task.user, content: content)
    end
  end

  def notify_failure_via_telegram(task, result)
    agent = task.agent
    user = task.user

    telegram_conv = user.conversations.find_by(agent: agent, channel: "telegram")
    return unless telegram_conv

    error_detail = result.timed_out ? "timed out" : "exit code #{result.exit_code}"
    stderr_snippet = result.stderr.to_s.truncate(500)
    text = "Scheduled task \"#{task.description}\" has failed #{task.consecutive_failures} times in a row (#{error_detail}). " \
           "I've disabled it to prevent further failures.\n\n" \
           "Last error: #{stderr_snippet.presence || '(no stderr)'}"

    msg = telegram_conv.messages.create!(
      workspace: task.workspace,
      user: user,
      role: "assistant",
      content: text,
      metadata: { source: "scheduled_task_failure", scheduled_task_id: task.id }
    )

    Adapters::Telegram.new(bot_token: agent.telegram_bot_token).send_reply(telegram_conv, msg)
    task.cancel!
  rescue => e
    Rails.logger.error("[RunScheduledTaskJob] Failed to send failure notification: #{e.message}")
    task.cancel!
  end

  def build_trigger_content(task, result)
    parts = ["[Scheduled Task: #{task.description}]"]
    parts << "[Tool: #{task.agent_tool.name}]"

    if result.timed_out
      parts << "[Status: timed out]"
      parts << result.stderr if result.stderr.present?
    elsif result.exit_code != 0
      parts << "[Status: failed, exit code #{result.exit_code}]"
      parts << result.stderr if result.stderr.present?
      parts << result.stdout if result.stdout.present?
    else
      parts << result.stdout
    end

    parts.join("\n")
  end
end
