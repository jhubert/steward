class AddVectorSupportToMemoryItems < ActiveRecord::Migration[8.1]
  def change
    enable_extension "vector"
    add_column :memory_items, :embedding, :vector, limit: 1536
    add_index :memory_items, :embedding, using: :hnsw, opclass: :vector_cosine_ops
  end
end
