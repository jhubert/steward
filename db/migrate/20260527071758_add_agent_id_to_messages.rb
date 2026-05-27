class AddAgentIdToMessages < ActiveRecord::Migration[8.1]
  def up
    # Add nullable first to allow backfill
    add_column :messages, :agent_id, :bigint
    add_index :messages, [:user_id, :agent_id, :created_at],
              name: "idx_messages_user_agent_created"

    # Backfill from conversations
    execute <<~SQL
      UPDATE messages
      SET agent_id = conversations.agent_id
      FROM conversations
      WHERE messages.conversation_id = conversations.id
        AND messages.agent_id IS NULL
    SQL

    change_column_null :messages, :agent_id, false
    add_foreign_key :messages, :agents
  end

  def down
    remove_foreign_key :messages, :agents
    remove_index :messages, name: "idx_messages_user_agent_created"
    remove_column :messages, :agent_id
  end
end
