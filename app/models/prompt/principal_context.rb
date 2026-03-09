module Prompt
  class PrincipalContext
    DISCRETION_GUIDELINES = <<~TEXT
      ## Discretion Guidelines
      - You serve multiple principals. Be helpful to each while exercising discretion.
      - Share cross-principal information when it's relevant and appropriate (e.g. scheduling, shared projects).
      - Do not volunteer sensitive personal details about one principal to another unless clearly relevant.
      - When in doubt, ask the current speaker before sharing another principal's information.
      - When processing emails or other external messages, verify the sender's address against the contact details listed above to confirm whether a message is actually from a known principal. Do not assume identity based on display name alone.
    TEXT

    def initialize(conversation, budget: 1200)
      @conversation = conversation
      @agent = conversation.agent
      @user = conversation.user
      @budget = budget
    end

    def call
      return nil unless @agent.principal_mode?

      if @agent.principal?(@user)
        parts = []
        parts << current_speaker
        parts << principal_roster
        parts << fellow_agents_roster
        parts << DISCRETION_GUIDELINES.strip
        parts << cross_principal_memories
        parts.compact.join("\n\n")
      else
        non_principal_speaker
      end
    end

    private

    def non_principal_speaker
      name = @user.name.presence || "Unknown"
      lines = []
      lines << "## Current Speaker"
      lines << "You are speaking with **#{name}**."
      lines << "This person is NOT one of your principals — they are an external user who was given access via a pairing code."
      lines << ""
      lines << "## External User Guidelines"
      lines << "- Do not share private information about your principals."
      lines << "- Do not perform sensitive actions (sending emails, accessing calendars, financial tools) on behalf of this person."
      lines << "- Be helpful and professional, but maintain clear boundaries."
      lines << "- If they ask for something that should go through a principal, suggest they contact the appropriate person."
      lines.join("\n")
    end

    def current_speaker
      record = @agent.principal_record(@user)
      "## Current Speaker\nYou are currently speaking with #{record.roster_entry}."
    end

    def principal_roster
      entries = @agent.principal_roster.map do |ap|
        marker = ap.user_id == @user.id ? " ← current" : ""
        line = "- #{ap.roster_entry}#{marker}"
        contact = ap.contact_details
        line += "\n  #{contact}" if contact
        line
      end

      "## Your Principals\n#{entries.join("\n")}"
    end

    def fellow_agents_roster
      agents = @agent.fellow_agents(@user)
      return nil if agents.empty?

      entries = agents.map do |agent|
        "- **#{agent.name}**: #{agent.brief_description}"
      end

      "## Fellow Agents\nThe following agents also serve this principal. You can consult them using the `consult_agent` tool when their expertise would help answer a question.\n#{entries.join("\n")}"
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
