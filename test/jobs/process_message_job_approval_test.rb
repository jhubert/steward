require 'test_helper'

class ProcessMessageJobApprovalTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @agent = agents(:jennifer)
    @agent.update!(settings: @agent.settings.merge("approval_required_tools" => ["send_email"]))
    @conversation = conversations(:bob_jennifer)
    @message = messages(:bob_jennifer_hello)

    stub_adapter
  end

  test "approval-required tool call is queued, not executed; pending action persists; LLM gets queued_for_approval" do
    Approvals::TelegramPrompt.stubs(:deliver).returns(true)

    tool_use = build_tool_use_response(
      tool_name: "send_email",
      tool_id: "toolu_email_1",
      input: { "to" => "prospect@acme.com", "subject" => "Re: scheduling", "body" => "Tue 2pm works." }
    )
    follow_up_text = build_text_response("Got it, queued the draft.")

    seen_messages = []
    messages_api = stub
    messages_api.stubs(:create).with do |params|
      seen_messages << params[:messages]
      true
    end.returns(tool_use).then.returns(follow_up_text)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    assert_difference "PendingAction.count", 1 do
      ProcessMessageJob.perform_now(@message.id)
    end

    pa = PendingAction.last
    assert_equal "send_email", pa.tool_name
    assert_equal "prospect@acme.com", pa.tool_input["to"]
    assert_equal "pending", pa.status
    assert_equal users(:alice), pa.approver_user # falls back to first principal

    # The tool_result fed back to the LLM in round 2 should say queued_for_approval
    second_round = seen_messages.last
    tool_result_msg = second_round.find { |m| m[:role] == "user" && m[:content].is_a?(Array) }
    assert tool_result_msg, "expected a tool_result user message"
    blob = tool_result_msg[:content].first[:content].to_s
    assert_includes blob, "queued_for_approval"
    assert_includes blob, "pending_action_id=#{pa.id}"
  end

  test "gate falls through to normal execution when no approver is configured" do
    # Remove principals so approver_user returns nil
    @agent.agent_principals.destroy_all
    @agent.reload

    tool_use = build_tool_use_response(
      tool_name: "send_email",
      tool_id: "toolu_email_2",
      input: { "to" => "x@example.com", "subject" => "Hi", "body" => "Hello" }
    )
    text_resp = build_text_response("Email sent.")
    messages_api = stub
    messages_api.stubs(:create).returns(tool_use).then.returns(text_resp)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    # Stub email sending so it doesn't actually try to send.
    ProcessMessageJob.any_instance.stubs(:execute_virtual_tool).returns(
      { content: "ok", summary: { name: "send_email" }, log_entry: {} }
    )

    assert_no_difference "PendingAction.count" do
      ProcessMessageJob.perform_now(@message.id)
    end
  end

  test "all-principal recipients bypass the approval gate" do
    # bob is also a principal of jennifer; this is an internal-only email
    tool_use = build_tool_use_response(
      tool_name: "send_email",
      tool_id: "toolu_internal_1",
      input: { "to" => "alice@example.com", "cc" => "bob@example.com", "subject" => "FYI", "body" => "ok" }
    )
    text_resp = build_text_response("Sent.")
    messages_api = stub
    messages_api.stubs(:create).returns(tool_use).then.returns(text_resp)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    # Stub the actual email send so it doesn't try to hit Postmark/Gmail.
    ProcessMessageJob.any_instance.stubs(:execute_virtual_tool).returns(
      { content: "Email sent.", summary: { name: "send_email" }, log_entry: {} }
    )

    assert_no_difference "PendingAction.count" do
      ProcessMessageJob.perform_now(@message.id)
    end
  end

  test "mixed recipients (one non-principal) still fire the gate" do
    Approvals::TelegramPrompt.stubs(:deliver).returns(true)
    tool_use = build_tool_use_response(
      tool_name: "send_email",
      tool_id: "toolu_mixed_1",
      input: { "to" => "alice@example.com", "cc" => "prospect@acme.com", "subject" => "X", "body" => "y" }
    )
    text_resp = build_text_response("Queued.")
    messages_api = stub
    messages_api.stubs(:create).returns(tool_use).then.returns(text_resp)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    assert_difference "PendingAction.count", 1 do
      ProcessMessageJob.perform_now(@message.id)
    end
  end

  test "execute_pending_action! bypasses the gate and runs the virtual tool" do
    Approvals::TelegramPrompt.stubs(:deliver).returns(true)

    pa = PendingAction.create!(
      workspace: workspaces(:default),
      agent: @agent,
      conversation: @conversation,
      approver_user: users(:alice),
      tool_name: "send_email",
      tool_input: { "to" => "x@example.com", "subject" => "Hi", "body" => "Hello" },
      tool_use_id: "toolu_x"
    )

    # Spy on execute_virtual_tool to make sure it gets called (not gated)
    ProcessMessageJob.any_instance.expects(:execute_virtual_tool).with("send_email", anything, @conversation).returns(
      { content: "Email sent successfully.", summary: {}, log_entry: {} }
    )

    result = ProcessMessageJob.execute_pending_action!(pa)
    assert_equal "Email sent successfully.", result[:content]
  end

  private

  def stub_adapter
    adapter = stub(send_typing: true, send_reply: true)
    Adapters::Telegram.stubs(:new).returns(adapter)
  end

  def build_text_response(text, input_tokens: 100, output_tokens: 50)
    content_block = Data.define(:type, :text).new(type: :text, text: text)
    usage = Data.define(:input_tokens, :output_tokens).new(input_tokens: input_tokens, output_tokens: output_tokens)
    Data.define(:content, :usage, :model, :stop_reason).new(
      content: [content_block], usage: usage, model: 'claude-sonnet-4-5-20250929', stop_reason: :end_turn
    )
  end

  def build_tool_use_response(tool_name:, tool_id:, input:, text: '', input_tokens: 100, output_tokens: 50)
    blocks = []
    blocks << Data.define(:type, :text).new(type: :text, text: text) if text.present?
    blocks << Data.define(:type, :id, :name, :input).new(type: :tool_use, id: tool_id, name: tool_name, input: input)
    usage = Data.define(:input_tokens, :output_tokens).new(input_tokens: input_tokens, output_tokens: output_tokens)
    Data.define(:content, :usage, :model, :stop_reason).new(
      content: blocks, usage: usage, model: 'claude-sonnet-4-5-20250929', stop_reason: :tool_use
    )
  end
end
