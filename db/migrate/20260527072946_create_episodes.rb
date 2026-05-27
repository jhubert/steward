class CreateEpisodes < ActiveRecord::Migration[8.1]
  def change
    create_table :episodes do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :agent, null: false, foreign_key: true
      t.references :conversation, null: false, foreign_key: true

      t.string :title
      t.text :summary
      t.string :channel, null: false
      t.datetime :started_at, null: false
      t.datetime :ended_at, null: false
      t.bigint :first_message_id
      t.bigint :last_message_id
      t.vector :embedding, limit: 1536
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :episodes, [:workspace_id, :user_id, :agent_id, :started_at],
              name: "idx_episodes_relationship_time"
    add_index :episodes, [:embedding], using: :hnsw, opclass: :vector_cosine_ops,
              name: "index_episodes_on_embedding"
  end
end
