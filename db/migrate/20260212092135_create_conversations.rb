class CreateConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :conversations do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :agent, null: false, foreign_key: true
      t.string :channel, null: false
      t.string :external_thread_key
      t.string :title
      t.string :status, null: false, default: 'active'
      t.string :tags, array: true, default: []
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :conversations,
              %i[workspace_id user_id channel external_thread_key],
              unique: true,
              where: 'external_thread_key IS NOT NULL',
              name: 'idx_conversations_lookup'
  end
end
