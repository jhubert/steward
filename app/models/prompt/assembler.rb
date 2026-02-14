module Prompt
  class Assembler
    def initialize(conversation, incoming_message: nil)
      @conversation = conversation
      @agent = conversation.agent
      @state = conversation.ensure_state!
      @budgets = @agent.token_budgets
      @incoming_message = incoming_message
    end

    # Build the messages array for the LLM API call.
    # Does NOT include the new incoming message — that's appended by the caller.
    def call
      system_content = build_system_content
      history = build_history

      messages = [{ role: 'system', content: system_content }]
      messages.concat(history)
      messages
    end

    private

    def build_system_content
      parts = []
      parts << agent_core
      parts << date_context
      parts << principal_context if @agent.principal_mode?
      parts << skill_instructions if active_skills.any?
      parts << conversation_state if has_conversation_state?
      parts << long_term_recall if @incoming_message.present?
      parts << thread_catalog
      parts.compact.join("\n\n---\n\n")
    end

    def agent_core
      @agent.system_prompt
    end

    def date_context
      zone = ActiveSupport::TimeZone[@agent.settings&.dig("timezone") || "Pacific Time (US & Canada)"]
      now = Time.current.in_time_zone(zone)
      today = now.to_date

      lines = []
      lines << "## Current Date & Time"
      lines << "**Today: #{now.strftime('%A, %B %-d, %Y')}**"
      lines << "Current time: #{now.strftime('%-I:%M %p %Z')}"
      lines << ""
      lines << "### Calendar Reference"
      lines << "When mentioning dates, ALWAYS verify the day-of-week against this reference."
      lines << ""

      # Show 3 weeks: current week (Mon-Sun) + next 2 weeks
      week_start = today.beginning_of_week(:monday)
      3.times do |week|
        start = week_start + (week * 7)
        days = (0..6).map { |d| start + d }
        lines << days.map { |d|
          marker = d == today ? "**#{d.strftime('%a %-d')}**" : d.strftime('%a %-d')
          marker
        }.join(" | ")
      end

      lines.join("\n")
    end

    def principal_context
      Prompt::PrincipalContext.new(@conversation, budget: @budgets['principal_context']).call
    end

    def skill_instructions
      return nil if active_skills.empty?

      active_skills.map { |skill| skill[:instructions] }.join("\n\n---\n\n")
    end

    def active_skills
      @active_skills ||= Skills::Registry.instance.active_skills_for(@conversation)
    end

    def has_conversation_state?
      @state.summary.present? ||
        @state.pinned_facts.present? && @state.pinned_facts.any? ||
        @state.active_goals.present? && @state.active_goals.any? ||
        @state.tool_log.present? && @state.tool_log.any? ||
        @state.scratchpad.present?
    end

    def conversation_state
      parts = []

      parts << "## Conversation Summary So Far\n#{@state.summary}" if @state.summary.present?

      if @state.pinned_facts.present? && @state.pinned_facts.any?
        facts = @state.pinned_facts.map { |f| "- #{f}" }.join("\n")
        parts << "## Key Facts\n#{facts}"
      end

      if @state.active_goals.present? && @state.active_goals.any?
        goals = @state.active_goals.map { |g| "- #{g}" }.join("\n")
        parts << "## Active Goals\n#{goals}"
      end

      if @state.tool_log.present? && @state.tool_log.any?
        entries = @state.tool_log.last(5).map { |entry| format_tool_log_entry(entry) }
        parts << "## Recent Tool Activity\n#{entries.join("\n\n")}"
      end

      if @state.scratchpad.present?
        parts << "## Your Scratchpad\n#{@state.scratchpad.truncate(2000)}"
      end

      parts.join("\n\n")
    end

    def format_tool_log_entry(entry)
      timestamp = entry["timestamp"]
      rounds = entry["rounds"] || []
      lines = ["[#{timestamp}]"]
      rounds.each do |round|
        tool = round["tool"]
        input = round["input"]
        output = round["output"]
        exit_code = round["exit_code"]
        line = "- #{tool}"
        line += "(#{input})" if input.present?
        line += " → exit:#{exit_code}" if exit_code
        line += "\n  #{output.to_s.truncate(200)}" if output.present?
        lines << line
      end
      lines.join("\n")
    end

    def long_term_recall
      Memory::Retriever.new(@conversation, budget: @budgets['retrieval'] || 800).call(query: @incoming_message)
    end

    def thread_catalog
      other_threads = Conversation.where(
        workspace: @conversation.workspace,
        user: @conversation.user,
        agent: @conversation.agent
      ).where.not(id: @conversation.id)
       .where.not(title: nil)
       .order(updated_at: :desc)
       .limit(10)

      return nil if other_threads.empty?

      lines = other_threads.map { |c| "- #{c.title}" }
      "## Other Conversation Threads\n#{lines.join("\n")}"
    end

    def build_history
      recent = @conversation.messages.chronological.last(history_message_limit)

      recent.map do |msg|
        { role: msg.role, content: msg.content }
      end
    end

    def history_message_limit
      # Approximate: budget / avg tokens per message
      # Conservative estimate of ~40 tokens per message
      [(@budgets['history'] / 40), 100].min
    end
  end
end
