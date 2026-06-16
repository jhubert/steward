class ResolvePendingActionJob < ApplicationJob
  queue_as :default

  # decision: "approve" | "reject"
  # reject_note: optional text Jeremy added when rejecting
  def perform(pending_action_id, decision:, reject_note: nil)
    pending = PendingAction.unscoped.find(pending_action_id)

    Current.workspace = pending.workspace

    if pending.resolved?
      Rails.logger.info("[Approvals] pending_action=#{pending.id} already resolved (#{pending.status}); ignoring #{decision}")
      return
    end

    if pending.expired_now?
      pending.update!(status: "expired", resolved_at: Time.current)
      finalize_telegram(pending, "⏱ Approval expired before resolution.")
      reprompt_agent(pending, summary: "Approval for #{pending.tool_name} expired without a decision. Apologize briefly to the prospect for the delay or ask Jeremy how to handle it.")
      return
    end

    case decision.to_s
    when "approve"
      result = ProcessMessageJob.execute_pending_action!(pending)
      content = result[:content].to_s
      pending.update!(status: "approved", resolved_at: Time.current, result_summary: content.truncate(1000))
      finalize_telegram(pending, "✅ Sent.")
      reprompt_agent(pending, summary: approve_summary(pending, content))
    when "reject"
      pending.update!(status: "rejected", resolved_at: Time.current, reject_note: reject_note)
      finalize_telegram(pending, reject_note.present? ? "❌ Rejected: #{reject_note}" : "❌ Rejected.")
      reprompt_agent(pending, summary: reject_summary(pending, reject_note))
    else
      Rails.logger.warn("[Approvals] Unknown decision '#{decision}' for pending_action=#{pending.id}")
    end
  rescue => e
    Rails.logger.error("[Approvals] resolve failed pending=#{pending_action_id} decision=#{decision}: #{e.class}: #{e.message}")
    if pending && pending.pending?
      pending.update!(status: "failed", resolved_at: Time.current, error: "#{e.class}: #{e.message}".truncate(500))
      finalize_telegram(pending, "⚠️ Failed to apply: #{e.message.to_s.truncate(200)}")
    end
    raise
  end

  private

  def approve_summary(pending, content)
    excerpt = content.to_s.truncate(400)
    "Jeremy approved your #{pending.tool_name} (pending_action_id=#{pending.id}). " \
      "The action has been executed. Result:\n\n#{excerpt}\n\n" \
      "If there's anything else to do for the user, do it now. Otherwise end your turn."
  end

  def reject_summary(pending, note)
    base = "Jeremy rejected your #{pending.tool_name} (pending_action_id=#{pending.id})."
    base += "\n\nNote from Jeremy: #{note}" if note.present?
    base += "\n\nRevise based on the note and either re-attempt (a new approval will be requested) or stop."
    base
  end

  def finalize_telegram(pending, suffix)
    return unless pending.approval_chat_id && pending.approval_message_id
    adapter = Adapters::Telegram.new(bot_token: pending.agent.telegram_bot_token)
    new_text = "#{Approvals::TelegramPrompt.new(pending).send(:format_body)}\n\n— #{suffix}"
    adapter.edit_message_text(pending.approval_chat_id, pending.approval_message_id, new_text)
  rescue => e
    Rails.logger.warn("[Approvals] edit_message_text failed for pending=#{pending.id}: #{e.message}")
  end

  # Synthesize a system_instruction message in the conversation that triggered
  # the action. ProcessMessageJob recognizes the flag, surfaces it to the model
  # as a platform directive, and deletes the carrier message after processing.
  def reprompt_agent(pending, summary:)
    conv = pending.conversation
    msg = conv.messages.create!(
      workspace: conv.workspace,
      user: conv.user,
      role: "user",
      content: summary,
      metadata: {
        "system_instruction" => true,
        "source" => "approval_resolution",
        "pending_action_id" => pending.id
      }
    )
    ProcessMessageJob.perform_later(msg.id)
  end
end
