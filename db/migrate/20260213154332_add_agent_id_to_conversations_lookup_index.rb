class AddAgentIdToConversationsLookupIndex < ActiveRecord::Migration[8.1]
  def change
    remove_index :conversations, name: :idx_conversations_lookup
    add_index :conversations, [:workspace_id, :user_id, :agent_id, :channel, :external_thread_key],
              unique: true, name: :idx_conversations_lookup
  end
end
