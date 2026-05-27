class EmbedMessageJob < ApplicationJob
  queue_as :low_priority

  discard_on ActiveRecord::RecordNotFound

  retry_on Faraday::Error, wait: :polynomially_longer, attempts: 3

  # Generates an embedding for a Message so transcripts become semantically
  # searchable — feeds the search_transcripts virtual tool.
  def perform(message_id)
    client = Rails.configuration.openai_client
    return if client.nil?

    msg = Message.unscoped.find(message_id)
    return if msg.embedding.present?
    return if msg.content.blank?

    # Skip system messages (session-break notices etc.) — they aren't
    # meaningful as searchable content.
    return if msg.role == "system"

    input = msg.content.to_s.truncate(8000)

    response = client.embeddings(
      parameters: { model: "text-embedding-3-small", input: input }
    )

    vector = response.dig("data", 0, "embedding")
    return unless vector

    msg.update_columns(embedding: vector, embedded_at: Time.current)
  end
end
