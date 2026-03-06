class SplitConversationIndexForEmailThreads < ActiveRecord::Migration[8.1]
  def change
    # Remove the old single unique index
    remove_index :conversations, name: :idx_conversations_lookup

    # Non-email channels: keep per-user uniqueness (telegram, background, etc.)
    add_index :conversations,
      [:workspace_id, :user_id, :agent_id, :channel, :external_thread_key],
      unique: true,
      where: "channel != 'email'",
      name: :idx_conversations_non_email_lookup

    # Email channels: one conversation per thread per agent (user-independent)
    add_index :conversations,
      [:workspace_id, :agent_id, :channel, :external_thread_key],
      unique: true,
      where: "channel = 'email'",
      name: :idx_conversations_email_thread_lookup
  end
end
