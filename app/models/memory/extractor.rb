module Memory
  class Extractor
    VALID_CATEGORIES = %w[decision preference fact commitment].freeze

    PROMPT = <<~PROMPT
      You extract structured facts from a conversation exchange. For each meaningful fact, return a JSON array of objects with "category" and "content" keys.

      Categories:
      - decision: A choice or decision the user has made
      - preference: A stated preference, like, or dislike
      - fact: A factual detail about the user (name, location, job, etc.)
      - commitment: Something the user or assistant committed to doing

      Rules:
      - Only extract NEW information — skip anything already in the known facts below
      - Skip greetings, filler, and small talk with no factual content
      - Each content string should be a concise, standalone statement
      - Return an empty array [] if there is nothing worth extracting
      - Return ONLY the JSON array, no other text
    PROMPT

    def initialize(agent:)
      @agent = agent
    end

    def call(user_message:, assistant_reply:, context: [])
      content = build_prompt(user_message, assistant_reply, context)

      response = Rails.configuration.anthropic_client.messages.create(
        model: @agent.extraction_model,
        max_tokens: 1000,
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

    def build_prompt(user_message, assistant_reply, context)
      parts = []

      if context.any?
        known = context.map { |m| "- [#{m.category}] #{m.content}" }.join("\n")
        parts << "## Already Known Facts\n#{known}"
      end

      parts << "## User Message\n#{user_message}"
      parts << "## Assistant Reply\n#{assistant_reply}"
      parts << "## Task\nExtract new facts as a JSON array. Return [] if nothing new."

      parts.join("\n\n")
    end
  end
end
