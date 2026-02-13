class BackfillEmbeddingsJob < ApplicationJob
  queue_as :low_priority

  def perform
    MemoryItem.where(embedding: nil).find_each(batch_size: 100) do |item|
      GenerateEmbeddingJob.perform_later(item.id)
    end
  end
end
