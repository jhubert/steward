require "test_helper"

class ScheduledTaskTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
  end

  test "recurring? returns true when interval_seconds is set" do
    task = scheduled_tasks(:alice_daily_standup)
    assert task.recurring?
    assert_not task.one_time?
  end

  test "one_time? returns true when interval_seconds is nil" do
    task = scheduled_tasks(:alice_one_time_reminder)
    assert task.one_time?
    assert_not task.recurring?
  end

  test "due scope returns enabled tasks with next_run_at in the past" do
    task = scheduled_tasks(:alice_daily_standup)
    task.update!(next_run_at: 1.minute.ago)

    due_tasks = ScheduledTask.due
    assert_includes due_tasks, task
  end

  test "due scope excludes future tasks" do
    task = scheduled_tasks(:alice_daily_standup)
    task.update!(next_run_at: 1.hour.from_now)

    due_tasks = ScheduledTask.due
    assert_not_includes due_tasks, task
  end

  test "due scope excludes disabled tasks" do
    task = scheduled_tasks(:bob_disabled_task)
    task.update!(next_run_at: 1.minute.ago)

    as_workspace(:default)
    due_tasks = ScheduledTask.due
    assert_not_includes due_tasks, task
  end

  test "advance! bumps next_run_at for recurring task" do
    task = scheduled_tasks(:alice_daily_standup)
    original_next = 1.minute.ago
    task.update!(next_run_at: original_next)

    task.advance!

    task.reload
    assert task.next_run_at > Time.current
    assert_not_nil task.last_run_at
    assert task.enabled?
  end

  test "advance! skips past missed runs for recurring task" do
    task = scheduled_tasks(:alice_daily_standup)
    # Set next_run to 3 days ago — should skip ahead past all missed runs
    task.update!(next_run_at: 3.days.ago, interval_seconds: 86_400)

    task.advance!

    task.reload
    assert task.next_run_at > Time.current
    assert task.next_run_at < 1.day.from_now + 1.minute
  end

  test "advance! disables one-time task" do
    task = scheduled_tasks(:alice_one_time_reminder)
    task.update!(next_run_at: 1.minute.ago)

    task.advance!

    task.reload
    assert_not task.enabled?
    assert_not_nil task.last_run_at
  end

  test "cancel! disables the task" do
    task = scheduled_tasks(:alice_daily_standup)
    assert task.enabled?

    task.cancel!

    task.reload
    assert_not task.enabled?
  end

  test "validates description presence" do
    task = ScheduledTask.new(
      workspace: workspaces(:default),
      agent: agents(:jennifer),
      user: users(:alice),
      next_run_at: 1.hour.from_now
    )
    assert_not task.valid?
    assert_includes task.errors[:description], "can't be blank"
  end

  test "validates interval_seconds minimum of 60" do
    task = scheduled_tasks(:alice_daily_standup)
    task.interval_seconds = 30
    assert_not task.valid?
    assert task.errors[:interval_seconds].any?
  end

  test "allows nil interval_seconds for one-time tasks" do
    task = scheduled_tasks(:alice_one_time_reminder)
    assert_nil task.interval_seconds
    assert task.valid?
  end

  test "interval_description returns human-readable descriptions" do
    task = scheduled_tasks(:alice_daily_standup)
    assert_equal "daily", task.interval_description

    task.interval_seconds = 3600
    assert_equal "hourly", task.interval_description

    task.interval_seconds = 604_800
    assert_equal "weekly", task.interval_description

    task.interval_seconds = 7200
    assert_equal "every 7200 seconds", task.interval_description

    one_time = scheduled_tasks(:alice_one_time_reminder)
    assert_equal "once", one_time.interval_description
  end

  test "enabled scope returns only enabled tasks" do
    enabled = ScheduledTask.enabled
    assert_includes enabled, scheduled_tasks(:alice_daily_standup)
    assert_includes enabled, scheduled_tasks(:alice_one_time_reminder)
    assert_not_includes enabled, scheduled_tasks(:bob_disabled_task)
  end

  test "direct_execution? returns true when agent_tool is set" do
    task = scheduled_tasks(:alice_direct_mail_check)
    assert task.direct_execution?
  end

  test "direct_execution? returns false when agent_tool is nil" do
    task = scheduled_tasks(:alice_daily_standup)
    assert_not task.direct_execution?
  end

  test "validates agent_tool belongs to same agent" do
    task = scheduled_tasks(:alice_daily_standup)
    # steward agent has no tools, so use a tool from jennifer but assign to steward
    other_agent = agents(:steward)
    task.agent = other_agent
    task.agent_tool = agent_tools(:jennifer_scheduling)

    assert_not task.valid?
    assert_includes task.errors[:agent_tool], "must belong to the same agent"
  end

  test "allows agent_tool from the same agent" do
    task = scheduled_tasks(:alice_direct_mail_check)
    assert_equal task.agent, task.agent_tool.agent
    assert task.valid?
  end
end
