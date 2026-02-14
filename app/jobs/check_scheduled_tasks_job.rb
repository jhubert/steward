class CheckScheduledTasksJob < ApplicationJob
  queue_as :default

  def perform
    ScheduledTask.unscoped.where(enabled: true).where("next_run_at <= ?", Time.current).find_each do |task|
      RunScheduledTaskJob.perform_later(task.id)
    end
  end
end
