class AddVisibilityToMemoryItems < ActiveRecord::Migration[8.1]
  def change
    # Memories are agent-private by default — each agent only sees what it
    # extracted. `workspace` visibility promotes a fact into the shared
    # principal core: durable identity-level knowledge about a person that
    # every agent serving them should have, so they stop re-learning the
    # same things independently.
    #
    # Sharing is always bounded to a single (workspace, user). It never
    # crosses tenants and never crosses principals.
    add_column :memory_items, :visibility, :string, null: false, default: "agent"

    add_index :memory_items,
              %i[workspace_id user_id visibility],
              where: "superseded_at IS NULL",
              name: "idx_memory_items_shared_core"
  end
end
