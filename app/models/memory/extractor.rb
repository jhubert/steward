module Memory
  class Extractor
    VALID_CATEGORIES = %w[decision preference fact commitment episode observation].freeze

    # Categories that are private to the user they describe — never surfaced
    # to other principals. Observations are emotional/contextual notes the
    # agent forms about a person; they're useful for same-user continuity
    # but inappropriate to share across principals.
    PRIVATE_CATEGORIES = %w[observation].freeze

    PROMPT = <<~PROMPT
      You extract durable facts and impressions from a conversation segment
      that would be useful in FUTURE conversations with this user. Return a
      JSON array of objects with "category" and "content" keys. Each item
      may also include:
        - "observed_at" (ISO date when the fact became true, if mentioned)
        - "subject" (only for "commitment" items): "agent" if the AGENT
          promised to do something, "user" if the user did. Defaults to
          "user" if unclear.
        - "core": true if this belongs in the SHARED PRINCIPAL CORE (see
          below). Defaults to false.

      The shared principal core:
      Every agent serving this person can read core facts, so they don't each
      have to learn the same things separately. Mark an item core when it is
      durable, identity-level knowledge that ANY agent working for this person
      would benefit from — who they are, the people around them, where they
      live and work, their role, health constraints, and long-standing
      preferences about how they like to be worked with.

      Do NOT mark as core:
      - anything specific to one agent's domain or workstream
      - transient or in-progress details (this week's task, a pending draft)
      - "observation" items — emotional and tone signals stay with the agent
        that formed them, never shared
      - anything the person appears to have shared in confidence with this
        agent in particular

      When in doubt, leave it out. A fact that is merely useful is not core;
      a fact whose absence would make another agent visibly not know this
      person is core.

      Categories:
      - decision: A choice the user made (e.g., "chose Rails over Django")
      - preference: A stated preference or dislike (e.g., "prefers morning meetings")
      - fact: A factual detail about the user (e.g., "based in Toronto", "works at Acme Corp")
      - commitment: Something committed to for the future (by either side)
      - episode: A notable past event/exchange worth anchoring (e.g., "discussed wife's birthday venue options on Apr 14")
      - observation: A relationship/tone signal — emotional state, energy,
        context (e.g., "seemed stressed about the upcoming move", "in good
        spirits today"). Use sparingly — only when it's likely to matter
        in future interactions.

      Rules:
      - Only extract information useful in a DIFFERENT conversation days or weeks later
      - DO NOT extract: transient debugging state, tool availability,
        meta-commentary about the conversation itself
      - Only extract NEW information — skip anything substantively present
        in the known facts below
      - If a new fact REPLACES an existing one (e.g., the user moved cities),
        say so in the content and the system will handle supersession separately
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

        result = { category: category, content: content }
        if item['observed_at'].present?
          observed = parse_observed_at(item['observed_at'])
          result[:observed_at] = observed if observed
        end
        if category == 'commitment' && item['subject'].present?
          subject = item['subject'].to_s.strip
          result[:subject] = subject if %w[user agent].include?(subject)
        end
        # Private categories can never enter the shared core, whatever the
        # model claims — enforced here rather than trusted to the prompt.
        result[:core] = core?(item) && !PRIVATE_CATEGORIES.include?(category)
        result
      end
    rescue JSON::ParserError
      []
    end

    def core?(item)
      ActiveModel::Type::Boolean.new.cast(item['core']) || false
    end

    def parse_observed_at(value)
      Time.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
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
