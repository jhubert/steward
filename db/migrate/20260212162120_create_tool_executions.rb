class CreateToolExecutions < ActiveRecord::Migration[8.1]
  def change
    create_table :tool_executions do |t|
      t.bigint :workspace_id, null: false
      t.bigint :agent_tool_id, null: false
      t.bigint :conversation_id, null: false
      t.string :tool_use_id
      t.jsonb :input, default: {}
      t.text :output
      t.text :error
      t.integer :exit_code
      t.boolean :timed_out, default: false
      t.integer :duration_ms
      t.timestamps
    end

    add_index :tool_executions, :workspace_id
    add_index :tool_executions, :agent_tool_id
    add_index :tool_executions, :conversation_id
    add_foreign_key :tool_executions, :workspaces
    add_foreign_key :tool_executions, :agent_tools
    add_foreign_key :tool_executions, :conversations
  end
end
