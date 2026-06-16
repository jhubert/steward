require 'test_helper'

class ResolvePendingActionJobTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @agent = agents(:jennifer)
    @conversation = conversations(:alice_jennifer)
    @approver = users(:alice)

    @pending = PendingAction.create!(
      workspace: workspaces(:default),
      agent: @agent,
      conversation: @conversation,
      approver_user: @approver,
      tool_name: "send_email",
      tool_input: { "to" => "x@example.com", "subject" => "Hi", "body" => "Hello" },
      tool_use_id: "toolu_x",
      approval_chat_id: "111111",
      approval_message_id: 9999
    )

    # No-op Telegram edits during the job.
    Adapters::Telegram.any_instance.stubs(:edit_message_text).returns(true)
    # We don't actually want the agent to be re-invoked synchronously in these tests
    ProcessMessageJob.stubs(:perform_later)
  end

  test "approve executes the tool, marks approved, and reprompts the agent" do
    ProcessMessageJob.stubs(:execute_pending_action!).with(instance_of(PendingAction)).returns(
      { content: "Email sent to x@example.com.", summary: {}, log_entry: {} }
    )

    assert_difference -> { @conversation.messages.where(role: "user").count }, 1 do
      ResolvePendingActionJob.perform_now(@pending.id, decision: "approve")
    end

    @pending.reload
    assert_equal "approved", @pending.status
    assert_not_nil @pending.resolved_at
    assert_includes @pending.result_summary, "Email sent to"

    repromp = @conversation.messages.where(role: "user").order(:id).last
    assert_equal true, repromp.metadata["system_instruction"]
    assert_includes repromp.content, "approved"
    assert_includes repromp.content, "Email sent to"
  end

  test "reject marks rejected and reprompts with the note" do
    assert_difference -> { @conversation.messages.where(role: "user").count }, 1 do
      ResolvePendingActionJob.perform_now(@pending.id, decision: "reject", reject_note: "Too pushy — soften the close.")
    end

    @pending.reload
    assert_equal "rejected", @pending.status
    assert_equal "Too pushy — soften the close.", @pending.reject_note

    repromp = @conversation.messages.where(role: "user").order(:id).last
    assert_equal true, repromp.metadata["system_instruction"]
    assert_includes repromp.content, "rejected"
    assert_includes repromp.content, "Too pushy"
  end

  test "expired pending action is marked expired and not executed" do
    @pending.update!(expires_at: 1.hour.ago)
    ProcessMessageJob.expects(:execute_pending_action!).never

    ResolvePendingActionJob.perform_now(@pending.id, decision: "approve")
    @pending.reload
    assert_equal "expired", @pending.status
  end

  test "already-resolved action is a no-op" do
    @pending.update!(status: "approved", resolved_at: 1.minute.ago)
    ProcessMessageJob.expects(:execute_pending_action!).never

    assert_no_difference -> { @conversation.messages.count } do
      ResolvePendingActionJob.perform_now(@pending.id, decision: "approve")
    end
  end
end
