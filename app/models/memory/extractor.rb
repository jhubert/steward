module Memory
  class Extractor
    VALID_CATEGORIES = %w[decision preference fact commitment].freeze

    PROMPT = <<~PROMPT
      You extract durable facts from a conversation segment that would be useful
      in FUTURE conversations with this user. Return a JSON array of objects
      with "category" and "content" keys.

      Categories:
      - decision: A choice the user made (e.g., "chose Rails over Django")
      - preference: A stated preference or dislike (e.g., "prefers morning meetings")
      - fact: A factual detail about the user (e.g., "based in Toronto", "works at Acme Corp")
      - commitment: Something committed to for the future

      Rules:
      - Only extract information useful in a DIFFERENT conversation days or weeks later
      - DO NOT extract: observations about tone/mood, transient debugging state,
        tool availability, meta-commentary about the conversation itself
      - Only extract NEW information — skip anything in the known facts below
      - Write each item as a concise standalone statement in third person
      - Prefer extracting nothing over extracting noise. Return [] if nothing is durable.
      - Return ONLY the JSON array, no other text
    PROMPT

    def initialize(agent:)
      @agent = agent
    end

    def call(messages:, context: [])
      content = build_prompt(messages, context)

      response = Rails.configuration.anthropic_client.messages.create(
        model: @agent.extraction_model,
        max_tokens: 2000,
        system: PROMPT,
        messages: [{ role: 'user', content: content }]
      )

      parse_response(response.content.first.text)
    end

    def parse_response(text)
      json = text.gsub(/\A```(?:json)?\s*|\s*```\z/, '')
      items = JSON.parse(json)

      return [] unless items.is_a?(Array)

      items.filter_map do |item|
        next unless item.is_a?(Hash)
        category = item['category'].to_s.strip
        content = item['content'].to_s.strip
        next unless VALID_CATEGORIES.include?(category) && content.present?

        { category: category, content: content }
      end
    rescue JSON::ParserError
      []
    end

    def build_prompt(messages, context)
      parts = []

      if context.any?
        known = context.map { |m| "- [#{m.category}] #{m.content}" }.join("\n")
        parts << "## Already Known Facts\n#{known}"
      end

      transcript = messages.map { |m| "#{m.role.upcase}: #{m.content}" }.join("\n")
      parts << "## Conversation Segment\n#{transcript}"
      parts << "## Task\nExtract durable facts as a JSON array. Return [] if nothing is worth remembering."

      parts.join("\n\n")
    end
  end
end
