class CreateConversationStates < ActiveRecord::Migration[8.1]
  def change
    create_table :conversation_states do |t|
      t.references :conversation, null: false, foreign_key: true, index: { unique: true }
      t.references :workspace, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.text :summary
      t.jsonb :pinned_facts, default: []
      t.jsonb :active_goals, default: []
      t.bigint :summarized_through_message_id

      t.timestamps
    end
  end
end
