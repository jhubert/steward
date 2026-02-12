module Compaction
  class Summarizer
    PROMPT = <<~PROMPT
      You are a conversation summarizer. Your job is to produce a concise, accurate summary
      that preserves all important information for continuing the conversation.

      Rules:
      - Preserve key decisions, agreements, and commitments
      - Preserve user preferences and stated facts
      - Preserve any open questions or pending items
      - Be concise but never drop important details
      - Write in third person ("The user asked about...", "The assistant suggested...")
      - If there's an existing summary, merge the new messages into it
    PROMPT

    def initialize(agent:)
      @agent = agent
    end

    def call(existing_summary:, messages:)
      content = build_prompt(existing_summary, messages)

      response = ANTHROPIC_CLIENT.messages.create(
        model: @agent.summarization_model,
        max_tokens: 1500,
        system: PROMPT,
        messages: [{ role: 'user', content: content }]
      )

      response.content.first.text
    end

    private

    def build_prompt(existing_summary, messages)
      parts = []

      parts << "## Existing Summary\n#{existing_summary}" if existing_summary.present?

      transcript = messages.map { |m| "#{m.role.upcase}: #{m.content}" }.join("\n\n")
      parts << "## New Messages to Incorporate\n#{transcript}"

      parts << "## Task\nProduce an updated summary that merges the existing summary with the new messages. Keep it concise but complete."

      parts.join("\n\n")
    end
  end
end
