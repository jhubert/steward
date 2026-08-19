module Memory
  # Builds an Episode record from a span of conversation messages.
  #
  # An "episode" is a coherent narrative chunk — typically one continuous
  # session within a conversation, bounded by session breaks. Episodes give
  # the agent searchable past *exchanges* (not just extracted facts) so it
  # can later reconstruct what happened when.
  #
  # The builder runs a brief LLM call to produce title + summary, generates
  # an embedding for semantic episode search, and persists the record.
  class EpisodeBuilder
    PROMPT = <<~PROMPT
      You produce a short title and a 1-3 sentence summary of a conversation segment.

      The output should help a future reader quickly recall what happened — the
      kind of "I remember when we..." anchor a human collaborator would form.

      Return ONLY valid JSON with this exact shape, no other text:
      { "title": "<short title, 3-8 words>", "summary": "<1-3 sentences, third person>" }
    PROMPT

    def initialize(conversation:, messages: nil, first_message_id: nil, last_message_id: nil)
      @conversation = conversation
      @messages = messages
      @first_message_id = first_message_id
      @last_message_id = last_message_id
    end

    # Returns the persisted Episode, or nil if there's nothing to build.
    def call
      msgs = resolve_messages
      return nil if msgs.empty?

      title, summary = generate_title_and_summary(msgs)
      return nil if summary.blank?

      embedding = generate_embedding("#{title}\n#{summary}")

      Episode.create!(
        workspace: @conversation.workspace,
        user: @conversation.user,
        agent: @conversation.agent,
        conversation: @conversation,
        title: title.to_s.truncate(200),
        summary: summary,
        channel: @conversation.channel,
        started_at: msgs.first.created_at,
        ended_at: msgs.last.created_at,
        first_message_id: msgs.first.id,
        last_message_id: msgs.last.id,
        embedding: embedding,
        metadata: episode_metadata(msgs)
      )
    end

    private

    def resolve_messages
      return @messages.to_a if @messages
      scope = @conversation.messages.chronological
      scope = scope.where('id >= ?', @first_message_id) if @first_message_id
      scope = scope.where('id <= ?', @last_message_id) if @last_message_id
      scope.to_a
    end

    def generate_title_and_summary(messages)
      transcript = messages.map { |m| "#{m.role.upcase}: #{m.content.to_s.truncate(800)}" }.join("\n\n")
      content = "## Conversation Segment\n#{transcript}\n\n## Task\nProduce the title and summary as JSON."

      response = Rails.configuration.anthropic_client.messages.create(
        model: @conversation.agent.extraction_model,
        max_tokens: 400,
        thinking: { type: 'disabled' },
        system: PROMPT,
        messages: [{ role: 'user', content: content }]
      )

      parse_json(response.content.find { |b| b.respond_to?(:text) }&.text.to_s)
    rescue StandardError => e
      Rails.logger.warn("[EpisodeBuilder] LLM call failed: #{e.message}")
      [nil, nil]
    end

    def parse_json(text)
      json = text.to_s.gsub(/\A```(?:json)?\s*|\s*```\z/, '')
      parsed = JSON.parse(json)
      return [nil, nil] unless parsed.is_a?(Hash)
      [parsed["title"].to_s.strip, parsed["summary"].to_s.strip]
    rescue JSON::ParserError
      [nil, nil]
    end

    def generate_embedding(text)
      client = Rails.configuration.openai_client
      return nil if client.nil? || text.blank?

      response = client.embeddings(
        parameters: { model: "text-embedding-3-small", input: text }
      )
      response.dig("data", 0, "embedding")
    rescue StandardError => e
      Rails.logger.warn("[EpisodeBuilder] Embedding failed: #{e.message}")
      nil
    end

    def episode_metadata(msgs)
      meta = { "message_count" => msgs.size }
      if @conversation.channel == "email"
        participants = @conversation.metadata&.dig("email_participants")
        meta["email_participants"] = participants if participants.present?
      end
      meta
    end
  end
end
