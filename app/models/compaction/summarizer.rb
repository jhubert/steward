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
      - When writing any specific date, verify the day-of-week against "Today's Date" below. If the existing summary contains dates that contradict today's actual date, correct them rather than preserving them.
      - Treat the existing summary as a draft, not as verified fact. Claims about system or tool mechanics (e.g. "duplicate firings", "retries", "race conditions") are especially prone to compounding: once stated, they get copied forward unchecked in every future summary. Before repeating such a claim, check whether the messages you can actually see support it. If they don't, drop the claim or rephrase it as something observed once rather than an ongoing system behavior.
    PROMPT

    def initialize(agent:)
      @agent = agent
    end

    def call(existing_summary:, messages:)
      content = build_prompt(existing_summary, messages)

      response = Rails.configuration.anthropic_client.messages.create(
        model: @agent.summarization_model,
        max_tokens: 1500,
        thinking: { type: 'disabled' },
        system: PROMPT,
        messages: [{ role: 'user', content: content }]
      )

      response.content.find { |b| b.respond_to?(:text) }&.text.to_s
    end

    private

    def build_prompt(existing_summary, messages)
      parts = []

      now = Time.current.in_time_zone(agent_tz)
      parts << "## Today's Date\n#{now.strftime('%A, %B %-d, %Y')} (current time: #{now.strftime('%-I:%M %p %Z')})"

      parts << "## Existing Summary\n#{existing_summary}" if existing_summary.present?

      transcript = messages.map do |m|
        ts = m.created_at.in_time_zone(agent_tz).strftime('%a %b %-d, %-I:%M %p %Z')
        "[#{ts}] #{m.role.upcase}: #{m.content}"
      end.join("\n\n")
      parts << "## New Messages to Incorporate\n#{transcript}"

      parts << "## Task\nProduce an updated summary that merges the existing summary with the new messages. Keep it concise but complete."

      parts.join("\n\n")
    end

    def agent_tz
      @agent_tz ||= ActiveSupport::TimeZone[@agent.settings&.dig("timezone") || "Pacific Time (US & Canada)"]
    end
  end
end
