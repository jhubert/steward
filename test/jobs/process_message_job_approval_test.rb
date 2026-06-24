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

  test "approval-required tool call to an external recipient is queued with the prepared payload" do
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
    assert_equal "Re: scheduling", pa.tool_input["subject"]
    assert_equal "pending", pa.status
    assert_equal users(:alice), pa.approver_user

    # The tool_result fed back to the LLM in round 2 should say queued_for_approval
    second_round = seen_messages.last
    tool_result_msg = second_round.find { |m| m[:role] == "user" && m[:content].is_a?(Array) }
    assert tool_result_msg, "expected a tool_result user message"
    blob = tool_result_msg[:content].first[:content].to_s
    assert_includes blob, "queued_for_approval"
    assert_includes blob, "pending_action_id=#{pa.id}"
  end

  test "pre-flight failure is reported to the LLM without queuing anything" do
    # Trigger a prepare failure by sending an empty body (validation rejects).
    tool_use = build_tool_use_response(
      tool_name: "send_email",
      tool_id: "toolu_empty",
      input: { "to" => "prospect@acme.com", "subject" => "Hi", "body" => "" }
    )
    follow_up = build_text_response("Will retry with content.")

    seen = []
    api = stub
    api.stubs(:create).with do |p|
      seen << p[:messages]
      true
    end.returns(tool_use).then.returns(follow_up)
    Rails.configuration.anthropic_client.stubs(:messages).returns(api)

    assert_no_difference "PendingAction.count" do
      ProcessMessageJob.perform_now(@message.id)
    end

    # The LLM gets the error verbatim so it can revise
    blob = seen.last.find { |m| m[:role] == "user" && m[:content].is_a?(Array) }[:content].first[:content].to_s
    assert_includes blob, "'to', 'subject', and 'body' are all required"
  end

  test "no approver configured → send_email_action called directly with prepared payload" do
    @agent.agent_principals.destroy_all
    @agent.reload

    tool_use = build_tool_use_response(
      tool_name: "send_email",
      tool_id: "toolu_no_approver",
      input: { "to" => "x@example.com", "subject" => "Hi", "body" => "Hello" }
    )
    text_resp = build_text_response("Email sent.")
    api = stub
    api.stubs(:create).returns(tool_use).then.returns(text_resp)
    Rails.configuration.anthropic_client.stubs(:messages).returns(api)

    ProcessMessageJob.any_instance.expects(:send_email_action).with(
      "send_email",
      has_entries("to" => "x@example.com", "subject" => "Hi", "body" => "Hello"),
      anything, anything
    ).returns({ content: "Email sent.", summary: {}, log_entry: {} })

    assert_no_difference "PendingAction.count" do
      ProcessMessageJob.perform_now(@message.id)
    end
  end

  test "all-principal recipients bypass the approval gate (auto_approve)" do
    tool_use = build_tool_use_response(
      tool_name: "send_email",
      tool_id: "toolu_internal_1",
      input: { "to" => "alice@example.com", "cc" => "bob@example.com", "subject" => "FYI", "body" => "ok" }
    )
    text_resp = build_text_response("Sent.")
    api = stub
    api.stubs(:create).returns(tool_use).then.returns(text_resp)
    Rails.configuration.anthropic_client.stubs(:messages).returns(api)

    # Confirm the send path is invoked directly with the prepared payload
    ProcessMessageJob.any_instance.expects(:send_email_action).with(
      "send_email",
      has_entries("to" => "alice@example.com", "cc" => "bob@example.com"),
      anything, anything
    ).returns({ content: "Email sent.", summary: {}, log_entry: {} })

    assert_no_difference "PendingAction.count" do
      ProcessMessageJob.perform_now(@message.id)
    end
  end

  test "mixed recipients (one external) still fire the gate" do
    Approvals::TelegramPrompt.stubs(:deliver).returns(true)
    tool_use = build_tool_use_response(
      tool_name: "send_email",
      tool_id: "toolu_mixed_1",
      input: { "to" => "alice@example.com", "cc" => "prospect@acme.com", "subject" => "X", "body" => "y" }
    )
    text_resp = build_text_response("Queued.")
    api = stub
    api.stubs(:create).returns(tool_use).then.returns(text_resp)
    Rails.configuration.anthropic_client.stubs(:messages).returns(api)

    assert_difference "PendingAction.count", 1 do
      ProcessMessageJob.perform_now(@message.id)
    end
  end

  test "execute_pending_action! for an email tool calls send_email_action with the stored payload" do
    pa = PendingAction.create!(
      workspace: workspaces(:default),
      agent: @agent,
      conversation: @conversation,
      approver_user: users(:alice),
      tool_name: "send_email",
      tool_input: { "to" => "x@example.com", "subject" => "Hi", "body" => "Hello" },
      tool_use_id: "toolu_x"
    )

    ProcessMessageJob.any_instance.expects(:send_email_action).with(
      "send_email", pa.tool_input, @agent, @conversation
    ).returns({ content: "Email sent successfully.", summary: {}, log_entry: {} })

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
