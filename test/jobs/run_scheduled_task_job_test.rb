require "test_helper"

class RunScheduledTaskJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    as_workspace(:default)
  end

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
end
