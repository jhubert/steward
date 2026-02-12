module Prompt
  class PrincipalContext
    DISCRETION_GUIDELINES = <<~TEXT
      ## Discretion Guidelines
      - You serve multiple principals. Be helpful to each while exercising discretion.
      - Share cross-principal information when it's relevant and appropriate (e.g. scheduling, shared projects).
      - Do not volunteer sensitive personal details about one principal to another unless clearly relevant.
      - When in doubt, ask the current speaker before sharing another principal's information.
    TEXT

    def initialize(conversation, budget: 1200)
      @conversation = conversation
      @agent = conversation.agent
      @user = conversation.user
      @budget = budget
    end

    def call
      return nil unless @agent.principal_mode?
      return nil unless @agent.principal?(@user)

      parts = []
      parts << current_speaker
      parts << principal_roster
      parts << DISCRETION_GUIDELINES.strip
      parts << cross_principal_memories

      parts.compact.join("\n\n")
    end

    private

    def current_speaker
      record = @agent.principal_record(@user)
      "## Current Speaker\nYou are currently speaking with #{record.roster_entry}."
    end

    def principal_roster
      entries = @agent.principal_roster.map do |ap|
        marker = ap.user_id == @user.id ? " ← current" : ""
        "- #{ap.roster_entry}#{marker}"
      end

      "## Your Principals\n#{entries.join("\n")}"
    end

    def cross_principal_memories
      fellows = @agent.fellow_principals(@user)
      return nil if fellows.empty?

      memory_budget = (@budget * 0.6).to_i
      chars_per_token = 4
      char_limit = memory_budget * chars_per_token

      sections = []
      chars_used = 0

      fellows.each do |ap|
        items = MemoryItem.where(user: ap.user).order(created_at: :desc).limit(20)
        next if items.empty?

        lines = []
        items.each do |item|
          line = "- [#{item.category}] #{item.content}"
          break if chars_used + line.length > char_limit
          chars_used += line.length
          lines << line
        end

        next if lines.empty?
        sections << "### #{ap.roster_entry}\n#{lines.join("\n")}"
      end

      return nil if sections.empty?

      "## Cross-Principal Context\n#{sections.join("\n\n")}"
    end
  end
end
