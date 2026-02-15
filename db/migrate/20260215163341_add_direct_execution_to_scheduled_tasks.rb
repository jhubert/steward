class AddDirectExecutionToScheduledTasks < ActiveRecord::Migration[8.1]
  def up
    add_reference :scheduled_tasks, :user, null: true, foreign_key: true
    add_reference :scheduled_tasks, :agent_tool, null: true, foreign_key: true
    add_column :scheduled_tasks, :tool_input, :jsonb, default: {}

    # Make conversation_id nullable
    change_column_null :scheduled_tasks, :conversation_id, true

    # Make tool_executions.conversation_id nullable (direct executions have no conversation)
    change_column_null :tool_executions, :conversation_id, true

    # Backfill user_id from conversation
    execute <<~SQL
      UPDATE scheduled_tasks
      SET user_id = conversations.user_id
      FROM conversations
      WHERE scheduled_tasks.conversation_id = conversations.id
        AND scheduled_tasks.user_id IS NULL
    SQL

    # Now enforce NOT NULL
    change_column_null :scheduled_tasks, :user_id, false
  end

  def down
    change_column_null :tool_executions, :conversation_id, false
    change_column_null :scheduled_tasks, :conversation_id, false

    remove_reference :scheduled_tasks, :agent_tool
    remove_reference :scheduled_tasks, :user
    remove_column :scheduled_tasks, :tool_input
  end
end
