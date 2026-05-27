class CreateMemoryAccessLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :memory_access_logs do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :agent, null: false, foreign_key: true
      t.references :viewing_user, null: false, foreign_key: { to_table: :users }
      t.references :subject_user, null: false, foreign_key: { to_table: :users }
      t.references :conversation, foreign_key: true
      t.string :context, null: false
      t.bigint :memory_item_id

      t.timestamps
    end

    add_index :memory_access_logs,
              [:workspace_id, :agent_id, :subject_user_id, :created_at],
              name: "idx_memory_access_logs_subject_time"
  end
end
