class GenerateTitleJob < ApplicationJob
  queue_as :low_priority

  discard_on ActiveRecord::RecordNotFound

  PROMPT = <<~PROMPT
    Generate a concise title (3-7 words) for this conversation. Return ONLY the title text, nothing else. No quotes, no punctuation at the end.
  PROMPT

  def perform(conversation_id)
    conversation = Conversation.find(conversation_id)
    return if conversation.title.present?

    Current.workspace = conversation.workspace

    messages = conversation.messages.chronological.limit(6)
    return if messages.empty?

    transcript = messages.map { |m| "#{m.role}: #{m.content.truncate(200)}" }.join("\n")

    response = Rails.configuration.anthropic_client.messages.create(
      model: conversation.agent.extraction_model,
      max_tokens: 30,
      system: PROMPT,
      messages: [{ role: "user", content: transcript }]
    )

    title = response.content.first.text.strip.truncate(100)
    conversation.update_column(:title, title) if title.present?
  end
end
