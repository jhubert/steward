class CreateMemoryItems < ActiveRecord::Migration[8.1]
  def change
    create_table :memory_items do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :conversation, foreign_key: true # nullable — cross-thread items
      t.string :category
      t.text :content, null: false
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :memory_items, %i[workspace_id user_id category]
  end
end
