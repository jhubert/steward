class CreateScheduledTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :scheduled_tasks do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :agent, null: false, foreign_key: true
      t.references :conversation, null: false, foreign_key: true
      t.text :description, null: false
      t.datetime :next_run_at, null: false
      t.integer :interval_seconds
      t.boolean :enabled, default: true, null: false
      t.datetime :last_run_at
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :scheduled_tasks, [:workspace_id, :agent_id]
    add_index :scheduled_tasks, [:enabled, :next_run_at]
    add_index :scheduled_tasks, [:workspace_id, :conversation_id]
  end
end
