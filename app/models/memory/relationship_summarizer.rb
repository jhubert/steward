module Memory
  # Builds (or refreshes) the per-(user, agent) relationship summary stored
  # on AgentUserState. Unlike per-conversation summaries, this one spans every
  # channel the user has used with this agent — it's the agent's running
  # mental model of the relationship.
  #
  # Inputs available to the LLM:
  #   - existing relationship summary (to preserve continuity)
  #   - per-conversation summaries across all this user's conversations
  #   - recent episode titles for orientation
  #   - last ~20 messages across all channels for freshness
  class RelationshipSummarizer
    PROMPT = <<~PROMPT
      You produce a concise running summary of the relationship between an
      AI agent and a specific user, spanning EVERY conversation they've had
      across all channels (Telegram, email, etc.).

      The summary's job is to give the agent a coherent "who is this person,
      what are we working on together, what's the current state" anchor at
      the top of every future conversation — independent of which channel.

      Rules:
      - 3-6 sentences. Concise but complete.
      - Lead with who the person is (role, context) if known.
      - Note ongoing projects, recurring themes, commitments either side
        has made, and any open threads.
      - Write in third person ("Jeremy is...", "The agent has been...").
      - Anchor important dates inline (e.g. "On April 14 they decided...").
      - If an existing summary is provided, MERGE rather than replace —
        preserve still-current facts, update what's changed.
      - Today's date will be supplied. Verify any date references against it.
    PROMPT

    def initialize(state)
      @state = state
      @user = state.user
      @agent = state.agent
    end

    def call
      transcript = build_input
      return nil if transcript.blank?

      response = Rails.configuration.anthropic_client.messages.create(
        model: @agent.summarization_model,
        max_tokens: 800,
        thinking: { type: 'disabled' },
        system: PROMPT,
        messages: [{ role: 'user', content: transcript }]
      )

      response.content.find { |b| b.respond_to?(:text) }&.text.to_s
    end

    private

    def build_input
      parts = []

      now = Time.current.in_time_zone(agent_tz)
      parts << "## Today's Date\n#{now.strftime('%A, %B %-d, %Y')}"

      parts << "## Person\n#{@user.name.presence || 'unnamed user'}"

      if @state.summary.present?
        parts << "## Existing Relationship Summary\n#{@state.summary}"
      end

      conv_summaries = conversation_summaries
      if conv_summaries.any?
        parts << "## Per-Conversation Summaries\n#{conv_summaries.join("\n\n")}"
      end

      episodes = recent_episodes
      if episodes.any?
        parts << "## Recent Episodes\n#{episodes.join("\n")}"
      end

      recent = recent_messages
      if recent.any?
        parts << "## Latest Messages (Across All Channels)\n#{recent.join("\n")}"
      end

      parts << "## Task\nProduce an updated relationship summary."
      parts.join("\n\n")
    end

    def conversation_summaries
      Conversation.where(workspace_id: @state.workspace_id,
                         user_id: @user.id,
                         agent_id: @agent.id)
                  .where.not(channel: "background")
                  .includes(:state)
                  .order(updated_at: :desc)
                  .limit(10)
                  .filter_map do |c|
        next if c.state&.summary.blank?
        "### [#{c.channel}] #{c.title.presence || 'untitled'} (last active #{c.updated_at.strftime('%b %-d')})\n#{c.state.summary.truncate(1200)}"
      end
    end

    def recent_episodes
      Episode.for_user_agent(@user, @agent)
             .recent.limit(8)
             .map do |ep|
        "- [#{ep.started_at.strftime('%b %-d')}] #{ep.title}: #{ep.summary.to_s.truncate(160)}"
      end
    end

    def recent_messages
      Message.for_user_agent(@user, @agent)
             .joins(:conversation)
             .where.not(conversations: { channel: "background" })
             .where.not(role: 'system')
             .order(created_at: :desc)
             .limit(20)
             .to_a.reverse
             .map do |m|
        time = m.created_at.in_time_zone(agent_tz).strftime('%a %b %-d, %-I:%M%P')
        "[#{time} #{m.conversation.channel}] #{m.role}: #{m.content.to_s.gsub(/\s+/, ' ').truncate(280)}"
      end
    end

    def agent_tz
      @agent_tz ||= ActiveSupport::TimeZone[@agent.settings&.dig("timezone") || "Pacific Time (US & Canada)"]
    end
  end
end
