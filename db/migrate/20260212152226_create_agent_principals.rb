class CreateAgentPrincipals < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_principals do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :agent, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :role
      t.string :display_name
      t.jsonb :permissions, default: {}
      t.jsonb :metadata, default: {}
      t.timestamps
    end

    add_index :agent_principals, [:workspace_id, :agent_id, :user_id],
              unique: true, name: "idx_agent_principals_unique"
  end
end
