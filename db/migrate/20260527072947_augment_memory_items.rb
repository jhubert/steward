class AugmentMemoryItems < ActiveRecord::Migration[8.1]
  def change
    add_reference :memory_items, :supersedes,
                  foreign_key: { to_table: :memory_items }, null: true, index: true
    add_column :memory_items, :superseded_at, :datetime
    add_column :memory_items, :observed_at, :datetime
    add_column :memory_items, :confidence, :float

    # Partial index keeps the "current memories" path fast as the
    # supersession chain grows over time.
    add_index :memory_items, [:workspace_id, :user_id, :agent_id],
              where: "superseded_at IS NULL",
              name: "idx_memory_items_current"
  end
end
