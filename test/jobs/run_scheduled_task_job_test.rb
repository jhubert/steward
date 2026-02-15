require "test_helper"

class RunScheduledTaskJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    as_workspace(:default)
  end

  # --- LLM path (no agent_tool) ---

  test "triggers background conversation and enqueues ProcessMessageJob" do
    task = scheduled_tasks(:alice_daily_standup)
    task.update_columns(next_run_at: 1.minute.ago)

    assert_difference "Message.count", 1 do
      assert_enqueued_with(job: ProcessMessageJob) do
        RunScheduledTaskJob.perform_now(task.id)
      end
    end

    message = Message.last
    assert_equal "user", message.role
    assert_match(/\[Scheduled Task\]/, message.content)
    assert_match(/standup/, message.content)
    assert_equal "trigger", message.metadata["source"]
    assert_equal "background", message.conversation.channel
  end

  test "advances recurring task after firing" do
    task = scheduled_tasks(:alice_daily_standup)
    original_next = 1.minute.ago
    task.update_columns(next_run_at: original_next)

    RunScheduledTaskJob.perform_now(task.id)

    task.reload
    assert task.next_run_at > Time.current
    assert task.enabled?
    assert_not_nil task.last_run_at
  end

  test "disables one-time task after firing" do
    task = scheduled_tasks(:alice_one_time_reminder)
    task.update_columns(next_run_at: 1.minute.ago)

    RunScheduledTaskJob.perform_now(task.id)

    task.reload
    assert_not task.enabled?
    assert_not_nil task.last_run_at
  end

  test "skips disabled tasks" do
    task = scheduled_tasks(:bob_disabled_task)
    task.update_columns(next_run_at: 1.minute.ago)

    assert_no_difference "Message.count" do
      assert_no_enqueued_jobs(only: ProcessMessageJob) do
        RunScheduledTaskJob.perform_now(task.id)
      end
    end
  end

  test "skips tasks with future next_run_at" do
    task = scheduled_tasks(:alice_daily_standup)
    # next_run_at is already in the future from fixture

    assert_no_difference "Message.count" do
      assert_no_enqueued_jobs(only: ProcessMessageJob) do
        RunScheduledTaskJob.perform_now(task.id)
      end
    end
  end

  test "handles missing task gracefully" do
    assert_nothing_raised do
      RunScheduledTaskJob.perform_now(-1)
    end
  end

  # --- Direct execution path ---

  test "direct execution with output triggers LLM" do
    task = scheduled_tasks(:alice_direct_mail_check)
    task.update_columns(next_run_at: 1.minute.ago)

    result = Tools::Executor::Result.new(
      stdout: "3 new emails found",
      stderr: "",
      exit_code: 0,
      timed_out: false
    )
    Tools::Executor.any_instance.stubs(:call).returns(result)

    assert_difference "ToolExecution.count", 1 do
      assert_difference "Message.count", 1 do
        assert_enqueued_with(job: ProcessMessageJob) do
          RunScheduledTaskJob.perform_now(task.id)
        end
      end
    end

    message = Message.last
    assert_match(/Check for new mail/, message.content)
    assert_match(/3 new emails found/, message.content)
    assert_equal "background", message.conversation.channel

    execution = ToolExecution.last
    assert_equal task.agent_tool, execution.agent_tool
    assert_nil execution.conversation
    assert_equal "3 new emails found", execution.output
    assert_equal 0, execution.exit_code
    assert_equal({ "attendees" => "alice@example.com" }, execution.input)
  end

  test "direct execution with empty output skips LLM" do
    task = scheduled_tasks(:alice_direct_mail_check)
    task.update_columns(next_run_at: 1.minute.ago)

    result = Tools::Executor::Result.new(
      stdout: "",
      stderr: "",
      exit_code: 0,
      timed_out: false
    )
    Tools::Executor.any_instance.stubs(:call).returns(result)

    assert_difference "ToolExecution.count", 1 do
      assert_no_difference "Message.count" do
        assert_no_enqueued_jobs(only: ProcessMessageJob) do
          RunScheduledTaskJob.perform_now(task.id)
        end
      end
    end
  end

  test "direct execution failure triggers LLM" do
    task = scheduled_tasks(:alice_direct_mail_check)
    task.update_columns(next_run_at: 1.minute.ago)

    result = Tools::Executor::Result.new(
      stdout: "",
      stderr: "Connection refused",
      exit_code: 1,
      timed_out: false
    )
    Tools::Executor.any_instance.stubs(:call).returns(result)

    assert_difference "ToolExecution.count", 1 do
      assert_enqueued_with(job: ProcessMessageJob) do
        RunScheduledTaskJob.perform_now(task.id)
      end
    end

    message = Message.last
    assert_match(/failed, exit code 1/, message.content)
    assert_match(/Connection refused/, message.content)
  end

  test "direct execution timeout triggers LLM" do
    task = scheduled_tasks(:alice_direct_mail_check)
    task.update_columns(next_run_at: 1.minute.ago)

    result = Tools::Executor::Result.new(
      stdout: "",
      stderr: "Execution timed out after 30 seconds",
      exit_code: nil,
      timed_out: true
    )
    Tools::Executor.any_instance.stubs(:call).returns(result)

    assert_enqueued_with(job: ProcessMessageJob) do
      RunScheduledTaskJob.perform_now(task.id)
    end

    message = Message.last
    assert_match(/timed out/, message.content)
  end

  test "direct execution injects STEWARD_USER_ID env var" do
    task = scheduled_tasks(:alice_direct_mail_check)
    task.update_columns(next_run_at: 1.minute.ago)

    captured_env = nil
    result = Tools::Executor::Result.new(stdout: "", stderr: "", exit_code: 0, timed_out: false)
    Tools::Executor.any_instance.stubs(:call).with { |input, extra_env:|
      captured_env = extra_env
      true
    }.returns(result)

    RunScheduledTaskJob.perform_now(task.id)

    assert_equal task.user_id.to_s, captured_env["STEWARD_USER_ID"]
  end

  test "direct execution advances the task" do
    task = scheduled_tasks(:alice_direct_mail_check)
    task.update_columns(next_run_at: 1.minute.ago)

    result = Tools::Executor::Result.new(stdout: "", stderr: "", exit_code: 0, timed_out: false)
    Tools::Executor.any_instance.stubs(:call).returns(result)

    RunScheduledTaskJob.perform_now(task.id)

    task.reload
    assert task.next_run_at > Time.current
    assert task.enabled?
  end
end
