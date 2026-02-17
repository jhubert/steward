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
      parts << platform_charter
      parts << agent_core
      parts << date_context
      parts << capabilities_context
      parts << principal_context if @agent.principal_mode?
      parts << skill_instructions if active_skills.any?
      parts << conversation_state if has_conversation_state?
      parts << long_term_recall if @incoming_message.present?
      parts << thread_catalog
      parts << background_context if @conversation.background?
      parts.compact.join("\n\n---\n\n")
    end

    def platform_charter
      @platform_charter ||= Rails.root.join('config', 'agent_charter.md').read.strip
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

    CAPABILITY_HINTS = {
      "download_file" => "Download files from URLs for the user (documents, images, data). Offer when they share a link or need to fetch something from the web.",
      "schedule_task" => "Schedule one-time or recurring tasks (reminders, daily standups, weekly reports). Proactively offer when the user mentions wanting to be reminded, needing recurring check-ins, or setting up routines.",
      "list_scheduled_tasks" => "List active scheduled tasks. Use when the user asks what's scheduled or wants to review their reminders.",
      "cancel_scheduled_task" => "Cancel a scheduled task. Use when the user wants to stop a reminder or recurring task.",
      "github" => "Access GitHub via the `gh` CLI. Can list/view/create PRs, issues, releases, search code, and call the GitHub API. Pass the full subcommand without the `gh` prefix (e.g. `pr list --repo owner/repo`).",
      "send_message" => "Send a message to the user via Telegram. Only available in background processing mode. Use sparingly — only for events important enough to interrupt the user."
    }.freeze

    def capabilities_context
      lines = ["## Your Capabilities"]
      lines << "You have access to the following tools. Use them proactively when relevant — don't wait to be asked if the situation clearly calls for one."
      lines << ""

      # Agent-specific tools
      @agent.enabled_tools.each do |tool|
        hint = CAPABILITY_HINTS[tool.name]
        desc = hint || tool.description
        lines << "- **#{tool.name}**: #{desc}"
      end

      # Builtin tools with hints (skip save_note/read_notes/google_setup — the LLM already understands those from the schema)
      %w[download_file schedule_task list_scheduled_tasks cancel_scheduled_task].each do |name|
        lines << "- **#{name}**: #{CAPABILITY_HINTS[name]}"
      end

      if @conversation.background?
        lines << "- **send_message**: #{CAPABILITY_HINTS['send_message']}"
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
       .where.not(channel: "background")
       .where.not(title: nil)
       .order(updated_at: :desc)
       .limit(10)

      return nil if other_threads.empty?

      lines = other_threads.map { |c| "- #{c.title}" }
      "## Other Conversation Threads\n#{lines.join("\n")}"
    end

    def background_context
      "## Background Processing Mode\n" \
      "You are processing a server-side event, NOT a live user chat. " \
      "Your text replies are logged but NOT delivered to anyone. " \
      "To notify the user, call the `send_message` tool. " \
      "Only send a message if the event is important enough to warrant interrupting them — " \
      "otherwise, take any needed actions (save notes, use tools) silently."
    end

    def build_history
      scope = @conversation.messages.chronological
      if @state.summarized_through_message_id
        scope = scope.where('id > ?', @state.summarized_through_message_id)
      end
      recent = scope.last(history_message_limit)

      # Anthropic API only accepts user/assistant roles in messages array;
      # filter out system messages (session break notices etc. live in the summary)
      recent.filter_map do |msg|
        next if msg.role == 'system'
        { role: msg.role, content: msg.content_blocks_for_api }
      end
    end

    def history_message_limit
      # Approximate: budget / avg tokens per message
      # Conservative estimate of ~40 tokens per message
      [(@budgets['history'] / 40), 100].min
    end
  end
end
