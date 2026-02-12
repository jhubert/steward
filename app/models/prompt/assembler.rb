module Prompt
  class Assembler
    def initialize(conversation)
      @conversation = conversation
      @agent = conversation.agent
      @state = conversation.ensure_state!
      @budgets = @agent.token_budgets
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
      parts << skill_instructions if active_skills.any?
      parts << conversation_state if @state.summary.present? || @state.pinned_facts.present?
      parts.compact.join("\n\n---\n\n")
    end

    def agent_core
      @agent.system_prompt
    end

    def skill_instructions
      return nil if active_skills.empty?

      active_skills.map { |skill| skill[:instructions] }.join("\n\n---\n\n")
    end

    def active_skills
      @active_skills ||= Skills::Registry.instance.active_skills_for(@conversation)
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

      parts.join("\n\n")
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
