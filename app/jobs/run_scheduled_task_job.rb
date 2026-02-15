class RunScheduledTaskJob < ApplicationJob
  queue_as :default

  def perform(scheduled_task_id)
    task = ScheduledTask.unscoped.find_by(id: scheduled_task_id)
    return unless task
    return unless task.enabled?
    return unless task.next_run_at <= Time.current

    Current.workspace = task.workspace

    task.advance!

    task.agent.trigger(
      user: task.conversation.user,
      content: "[Scheduled Task] #{task.description}"
    )
  end
end
