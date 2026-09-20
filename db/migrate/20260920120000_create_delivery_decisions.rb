class CreateDeliveryDecisions < ActiveRecord::Migration[8.1]
  def change
    create_table :delivery_decisions do |t|
      t.bigint :workspace_id, null: false
      t.bigint :agent_id, null: false
      t.bigint :conversation_id, null: false
      # The assistant reply being judged. Nullable so a decision survives the
      # message being destroyed (ephemeral system instructions get cleaned up
      # after delivery).
      t.bigint :message_id

      t.string :mode, null: false
      # What the gate concluded, and what actually happened. In shadow mode
      # these diverge on purpose — that difference is the whole dataset.
      t.boolean :would_deliver, null: false
      t.boolean :delivered, null: false
      t.string :reason, null: false

      t.jsonb :signals, default: {}
      t.integer :duration_ms
      t.integer :input_tokens

      t.timestamps
    end

    add_index :delivery_decisions, :workspace_id
    add_index :delivery_decisions, :conversation_id
    add_index :delivery_decisions, :message_id
    add_index :delivery_decisions, [:agent_id, :created_at]
    # The review query: "what would have been held".
    add_index :delivery_decisions, [:agent_id, :would_deliver, :created_at],
              name: "index_delivery_decisions_on_agent_and_verdict"
  end
end
