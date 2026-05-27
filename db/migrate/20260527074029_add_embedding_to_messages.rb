class AddEmbeddingToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :embedding, :vector, limit: 1536
    add_column :messages, :embedded_at, :datetime
    add_index :messages, [:embedding], using: :hnsw, opclass: :vector_cosine_ops,
              name: "index_messages_on_embedding"
  end
end
