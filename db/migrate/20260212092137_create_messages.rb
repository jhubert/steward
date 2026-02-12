class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :messages do |t|
      t.references :conversation, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :role, null: false
      t.text :content, null: false
      t.integer :token_count
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :messages, %i[conversation_id created_at]
  end
end
