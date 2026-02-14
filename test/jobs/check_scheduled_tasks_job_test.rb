require "test_helper"

class CheckScheduledTasksJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    as_workspace(:default)
  end

  test "enqueues RunScheduledTaskJob for due tasks" do
    task = scheduled_tasks(:alice_daily_standup)
    task.update_columns(next_run_at: 1.minute.ago)

    assert_enqueued_with(job: RunScheduledTaskJob, args: [task.id]) do
      CheckScheduledTasksJob.perform_now
    end
  end

  test "does not enqueue for future tasks" do
    # All fixture tasks have next_run_at in the future
    assert_no_enqueued_jobs(only: RunScheduledTaskJob) do
      CheckScheduledTasksJob.perform_now
    end
  end

  test "does not enqueue for disabled tasks" do
    task = scheduled_tasks(:bob_disabled_task)
    task.update_columns(next_run_at: 1.minute.ago)

    assert_no_enqueued_jobs(only: RunScheduledTaskJob) do
      CheckScheduledTasksJob.perform_now
    end
  end

  test "enqueues multiple due tasks" do
    task1 = scheduled_tasks(:alice_daily_standup)
    task2 = scheduled_tasks(:alice_one_time_reminder)
    task1.update_columns(next_run_at: 1.minute.ago)
    task2.update_columns(next_run_at: 2.minutes.ago)

    assert_enqueued_jobs(2, only: RunScheduledTaskJob) do
      CheckScheduledTasksJob.perform_now
    end
  end
end
