class CreateAgentTools < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_tools do |t|
      t.bigint :workspace_id, null: false
      t.bigint :agent_id, null: false
      t.string :name, null: false
      t.text :description, null: false
      t.jsonb :input_schema, null: false, default: {}
      t.text :command_template, null: false
      t.string :working_directory
      t.text :credentials_json
      t.integer :timeout_seconds, default: 30
      t.boolean :enabled, default: true
      t.jsonb :metadata, default: {}
      t.timestamps
    end

    add_index :agent_tools, [:workspace_id, :agent_id, :name], unique: true, name: "idx_agent_tools_unique"
    add_index :agent_tools, :workspace_id
    add_index :agent_tools, :agent_id
    add_foreign_key :agent_tools, :workspaces
    add_foreign_key :agent_tools, :agents
  end
end
