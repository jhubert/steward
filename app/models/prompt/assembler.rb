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
      parts << background_activity_briefing unless @conversation.background?
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
      "send_message" => "Send a message to the user via Telegram or email (whichever channel they use). Only available in background processing mode. Use sparingly — only for events important enough to interrupt the user.",
      "recall" => "Search your long-term memory with a targeted query. Use when you need to remember something specific — a past decision, preference, or fact — that isn't in your current context.",
      "read_transcript" => "Read the original conversation messages that produced a memory. Use after `recall` to get full context around a remembered fact.",
      "invite_user" => "Invite a new user to the platform by email. Use when a principal asks you to invite someone. Creates their account and sends a welcome email.",
      "send_email" => "Compose and send an email to anyone. Use when a principal asks you to email someone — a client, colleague, or anyone else. You can start new threads or reply to existing ones. Recipients can reply and you'll handle their responses.",
      "consult_agent" => "Consult a fellow agent for their expert opinion. Use when another agent's expertise would help — e.g., asking a financial advisor about tax implications or a scheduling agent about availability."
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
      %w[download_file schedule_task list_scheduled_tasks cancel_scheduled_task recall read_transcript].each do |name|
        lines << "- **#{name}**: #{CAPABILITY_HINTS[name]}"
      end

      if @conversation.background?
        lines << "- **send_message**: #{CAPABILITY_HINTS['send_message']}"
      end

      if @agent.settings&.dig("can_invite")
        lines << "- **invite_user**: #{CAPABILITY_HINTS['invite_user']}"
      end

      if @agent.email_handle.present?
        lines << "- **send_email**: #{CAPABILITY_HINTS['send_email']}"
      end

      if @agent.principal_mode? && @conversation.user && @agent.fellow_agents(@conversation.user).any?
        lines << "- **consult_agent**: #{CAPABILITY_HINTS['consult_agent']}"
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

    BACKGROUND_STALENESS_HOURS = 24

    def background_activity_briefing
      bg_conversation = find_background_conversation
      return nil unless bg_conversation

      last_bg_message = bg_conversation.messages.chronological.last
      return nil unless last_bg_message
      return nil if last_bg_message.created_at < BACKGROUND_STALENESS_HOURS.hours.ago

      char_budget = (@budgets['background_activity'] || 800) * 4
      parts = []

      # Background state summary (compacted history)
      bg_state = bg_conversation.state
      if bg_state&.summary.present?
        parts << "### Background Summary\n#{bg_state.summary.truncate(char_budget / 4)}"
      end

      # Recent tool log entries
      if bg_state&.tool_log.present? && bg_state.tool_log.any?
        entries = bg_state.tool_log.last(3).map { |entry| format_tool_log_entry(entry) }
        parts << "### Recent Background Tool Activity\n#{entries.join("\n\n")}"
      end

      # Background scratchpad
      if bg_state&.scratchpad.present?
        parts << "### Background Working Notes\n#{bg_state.scratchpad.truncate(char_budget / 4)}"
      end

      # Recent background messages (freshest context)
      recent_msgs = bg_conversation.messages.chronological.last(10)
      if recent_msgs.any?
        lines = recent_msgs.map do |msg|
          timestamp = msg.created_at.strftime('%H:%M')
          role_label = msg.role == 'user' ? 'trigger' : 'assistant'
          "[#{timestamp}] #{role_label}: #{msg.content.to_s.truncate(300)}"
        end
        parts << "### Recent Background Messages\n#{lines.join("\n")}"
      end

      return nil if parts.empty?

      briefing = parts.join("\n\n").truncate(char_budget)
      "## Background Activity Briefing\n" \
      "Your background process has been working autonomously. Here's what it's been doing — " \
      "use this to understand any references the user makes to background activity.\n\n#{briefing}"
    end

    def find_background_conversation
      Conversation.find_by(
        workspace: @conversation.workspace,
        user: @conversation.user,
        agent: @conversation.agent,
        channel: "background"
      )
    end

    # How many messages before the summary cutoff to keep as overlap.
    # Preserves immediate conversational context that the summary may
    # not capture in enough detail (e.g. a back-and-forth that was
    # just compacted seconds ago).
    OVERLAP_MESSAGES = 6

    def build_history
      if @state.summarized_through_message_id
        # Messages after the summary cutoff (the primary window)
        post = @conversation.messages.chronological
                 .where('id > ?', @state.summarized_through_message_id).to_a

        # Overlap: keep a few messages from just before the cutoff for continuity
        overlap = @conversation.messages.chronological
                    .where('id <= ?', @state.summarized_through_message_id)
                    .last(OVERLAP_MESSAGES)

        recent = (overlap + post).last(history_message_limit)
      else
        recent = @conversation.messages.chronological.last(history_message_limit)
      end

      # Anthropic API only accepts user/assistant roles in messages array;
      # filter out system messages (session break notices etc. live in the summary)
      multi_party_email = email_multi_party?
      recent.filter_map do |msg|
        next if msg.role == 'system'

        content = msg.content_blocks_for_api

        # In multi-party email threads, label user messages with sender info
        if multi_party_email && msg.role == 'user'
          sender_email = msg.metadata&.dig("sender_email")
          sender_name = msg.metadata&.dig("sender_name")
          if sender_email.present?
            label = sender_name.present? ? "#{sender_name} <#{sender_email}>" : sender_email
            content = prepend_sender_label(content, label)
          end
        end

        { role: msg.role, content: content }
      end
    end

    def email_multi_party?
      @conversation.channel == "email" &&
        (@conversation.metadata&.dig("email_participants") || []).size > 1
    end

    def prepend_sender_label(content_blocks, label)
      prefix = "[From: #{label}]\n"
      if content_blocks.is_a?(Array)
        # Find first text block and prepend
        content_blocks.map.with_index do |block, i|
          if i == 0 && block.is_a?(Hash) && block[:type] == "text"
            block.merge(text: prefix + block[:text])
          elsif i == 0 && block.is_a?(String)
            prefix + block
          else
            block
          end
        end
      else
        prefix + content_blocks.to_s
      end
    end

    def history_message_limit
      # Approximate: budget / avg tokens per message
      # Conservative estimate of ~40 tokens per message
      [(@budgets['history'] / 40), 100].min
    end
  end
end
