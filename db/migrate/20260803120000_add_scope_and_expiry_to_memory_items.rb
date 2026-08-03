class AddScopeAndExpiryToMemoryItems < ActiveRecord::Migration[8.1]
  def change
    # Distinguishes knowledge *about the principal* from general world facts an
    # agent happened to learn while researching. Only principal-scoped memories
    # are injected into Layer D by default — world facts stay searchable via the
    # `recall` tool but no longer compete for the retrieval budget.
    add_column :memory_items, :subject_scope, :string, null: false, default: "principal"

    # Facts with a shelf life (a scheduled meeting, this quarter's numbers).
    # NULL means the fact does not expire.
    add_column :memory_items, :expires_at, :datetime

    add_index :memory_items,
              %i[workspace_id user_id agent_id subject_scope],
              where: "superseded_at IS NULL",
              name: "idx_memory_items_current_scoped"

    add_index :memory_items, :expires_at, where: "expires_at IS NOT NULL"
  end
end
