class AddConsecutiveFailuresToScheduledTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :scheduled_tasks, :consecutive_failures, :integer, default: 0, null: false
  end
end
