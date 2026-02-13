class GenerateEmbeddingJob < ApplicationJob
  queue_as :low_priority

  discard_on ActiveRecord::RecordNotFound

  retry_on Faraday::Error, wait: :polynomially_longer, attempts: 3

  def perform(memory_item_id)
    client = Rails.configuration.openai_client
    return if client.nil?

    item = MemoryItem.find(memory_item_id)
    return if item.embedding.present?

    input = "[#{item.category}] #{item.content}"

    response = client.embeddings(
      parameters: { model: "text-embedding-3-small", input: input }
    )

    vector = response.dig("data", 0, "embedding")
    return unless vector

    item.update!(embedding: vector)
  end
end
