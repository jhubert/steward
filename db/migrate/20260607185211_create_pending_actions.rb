class CreatePendingActions < ActiveRecord::Migration[8.1]
  def change
    create_table :pending_actions do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :agent, null: false, foreign_key: true
      t.references :conversation, null: false, foreign_key: true
      t.references :approver_user, null: false, foreign_key: { to_table: :users }
      t.references :source_message, null: true, foreign_key: { to_table: :messages }

      t.string  :tool_name, null: false
      t.jsonb   :tool_input, null: false, default: {}
      t.string  :tool_use_id

      t.string  :status, null: false, default: "pending"
      t.text    :reject_note
      t.text    :result_summary
      t.text    :error

      t.string  :approval_chat_id
      t.bigint  :approval_message_id

      t.datetime :resolved_at
      t.datetime :expires_at

      t.timestamps
    end

    add_index :pending_actions, :status
    add_index :pending_actions, [:agent_id, :status]
  end
end
