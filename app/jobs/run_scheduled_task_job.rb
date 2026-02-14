class RunScheduledTaskJob < ApplicationJob
  queue_as :default

  def perform(scheduled_task_id)
    task = ScheduledTask.unscoped.find_by(id: scheduled_task_id)
    return unless task
    return unless task.enabled?
    return unless task.next_run_at <= Time.current

    Current.workspace = task.workspace

    message = task.conversation.messages.create!(
      workspace: task.workspace,
      user: task.conversation.user,
      role: "user",
      content: "[Scheduled Task] #{task.description}",
      metadata: { "source" => "scheduled_task", "scheduled_task_id" => task.id }
    )

    task.advance!

    ProcessMessageJob.perform_later(message.id)
  end
end
