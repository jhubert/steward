module Approvals
  # Formats a PendingAction as a Telegram message with inline Approve/Reject
  # buttons and delivers it to the approver's chat with the agent.
  class TelegramPrompt
    def self.deliver(pending_action)
      new(pending_action).deliver
    end

    def initialize(pending_action)
      @pending = pending_action
      @agent = pending_action.agent
    end

    def deliver
      approver = @pending.approver_user
      conv = @agent.approval_conversation_for(approver)
      unless conv
        Rails.logger.warn("[Approvals] No Telegram conversation for approver=#{approver&.id} agent=#{@agent.id}; pending_action=#{@pending.id} undelivered")
        return false
      end

      adapter = Adapters::Telegram.new(bot_token: @agent.telegram_bot_token)
      body = format_body
      buttons = [
        [
          { text: "✅ Send",   callback_data: @pending.callback_data("approve") },
          { text: "❌ Reject", callback_data: @pending.callback_data("reject")  }
        ]
      ]

      response = adapter.send_text_with_keyboard(conv.external_thread_key, body, buttons)
      result = response.is_a?(Hash) ? response["result"] : nil
      @pending.update!(
        approval_chat_id: conv.external_thread_key,
        approval_message_id: result&.dig("message_id")
      )
      true
    rescue => e
      Rails.logger.error("[Approvals] Failed to deliver approval prompt #{@pending.id}: #{e.class}: #{e.message}")
      false
    end

    private

    def format_body
      header = "*#{@agent.name} wants to #{action_label}*"
      detail = format_detail
      footer = "Tap *Send* to approve, *Reject* to send Jennifer back with a note."
      [header, detail, footer].compact.join("\n\n")
    end

    def action_label
      case @pending.tool_name
      when "send_email", "gmail_new_thread" then "send an email"
      when "gmail_reply" then "reply to an email thread"
      else @pending.tool_name.to_s.tr("_", " ")
      end
    end

    def format_detail
      input = @pending.tool_input || {}
      case @pending.tool_name
      when "send_email", "gmail_new_thread"
        to = input["to"].to_s
        cc = input["cc"].to_s.presence
        subject = input["subject"].to_s
        body = input["body"].to_s
        lines = ["📧 *To:* #{to}"]
        lines << "*Cc:* #{cc}" if cc
        lines << "*Subject:* #{subject}"
        lines << ""
        lines << truncate(body, 1500)
        lines.join("\n")
      when "gmail_reply"
        thread_id = input["thread_id"].to_s
        body = input["body"].to_s
        ["📧 *Reply in thread:* `#{thread_id}`", "", truncate(body, 1500)].join("\n")
      else
        "```\n#{truncate(JSON.pretty_generate(input), 1500)}\n```"
      end
    end

    def truncate(str, n)
      s = str.to_s
      s.length > n ? "#{s[0, n]}\n…(truncated)" : s
    end
  end
end
