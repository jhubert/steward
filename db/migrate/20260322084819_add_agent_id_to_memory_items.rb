class AddAgentIdToMemoryItems < ActiveRecord::Migration[8.1]
  def up
    add_reference :memory_items, :agent, null: true, foreign_key: true

    # Backfill from conversation's agent
    execute <<~SQL
      UPDATE memory_items
      SET agent_id = conversations.agent_id
      FROM conversations
      WHERE memory_items.conversation_id = conversations.id
        AND memory_items.agent_id IS NULL
    SQL
  end

  def down
    remove_reference :memory_items, :agent
  end
end
