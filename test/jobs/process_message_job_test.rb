require 'test_helper'
require 'open3'

class ProcessMessageJobTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @conversation = conversations(:alice_telegram)
    @message = messages(:alice_hello)
    stub_adapter
  end

  test 'text-only response without tools works as before' do
    stub_text_response('Hello Alice!')

    assert_difference 'Message.count', 1 do
      ProcessMessageJob.perform_now(@message.id)
    end

    reply = Message.last
    assert_equal 'assistant', reply.role
    assert_equal 'Hello Alice!', reply.content
    assert_nil reply.metadata['tool_calls']
  end

  test 'tool_use response triggers execution and continues to final reply' do
    # First response: tool_use, second response: text
    tool_use_response = build_tool_use_response(
      tool_name: 'find_availability',
      tool_id: 'toolu_01',
      input: { 'attendees' => 'alice@example.com' }
    )
    text_response = build_text_response('Meeting slots available: Mon 2pm, Tue 3pm')

    messages_api = stub
    messages_api.stubs(:create).returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    # Setup: jennifer has tools, so use a jennifer conversation
    jennifer_conversation = conversations(:alice_jennifer)
    jennifer_message = messages(:alice_jennifer_hello)

    # Stub the tool execution
    status = stub(exitstatus: 0)
    Open3.stubs(:capture3).returns(['Mon 2pm, Tue 3pm', '', status])

    assert_difference 'Message.count', 1 do
      assert_difference 'ToolExecution.count', 1 do
        ProcessMessageJob.perform_now(jennifer_message.id)
      end
    end

    reply = Message.last
    assert_equal 'Meeting slots available: Mon 2pm, Tue 3pm', reply.content
    assert reply.metadata['tool_calls'].present?
    assert_equal 'find_availability', reply.metadata['tool_calls'].first['name']

    execution = ToolExecution.last
    assert_equal 'toolu_01', execution.tool_use_id
    assert_equal 0, execution.exit_code
    assert_equal false, execution.timed_out
  end

  test 'unknown tool returns error to LLM without crashing' do
    tool_use_response = build_tool_use_response(
      tool_name: 'nonexistent_tool',
      tool_id: 'toolu_99',
      input: {}
    )
    text_response = build_text_response("I couldn't find that tool.")

    messages_api = stub
    messages_api.stubs(:create).returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_conversation = conversations(:alice_jennifer)
    jennifer_message = messages(:alice_jennifer_hello)

    assert_no_difference 'ToolExecution.count' do
      ProcessMessageJob.perform_now(jennifer_message.id)
    end

    reply = Message.last
    assert_equal "I couldn't find that tool.", reply.content
  end

  test 'tool execution failure is reported back to LLM' do
    tool_use_response = build_tool_use_response(
      tool_name: 'find_availability',
      tool_id: 'toolu_02',
      input: { 'attendees' => 'bad@input' }
    )
    text_response = build_text_response('Sorry, there was an error checking the calendar.')

    messages_api = stub
    messages_api.stubs(:create).returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)

    status = stub(exitstatus: 1)
    Open3.stubs(:capture3).returns(['', 'Connection failed', status])

    ProcessMessageJob.perform_now(jennifer_message.id)

    reply = Message.last
    assert_equal 'Sorry, there was an error checking the calendar.', reply.content

    execution = ToolExecution.last
    assert_equal 1, execution.exit_code
    assert_equal 'Connection failed', execution.error
  end

  test 'max tool rounds safety valve stops loop' do
    # Build a response that always returns tool_use
    tool_use_response = build_tool_use_response(
      tool_name: 'search_contacts',
      tool_id: 'toolu_loop',
      input: { 'query' => 'test' },
      text: ''
    )

    messages_api = stub
    messages_api.stubs(:create).returns(tool_use_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)

    status = stub(exitstatus: 0)
    Open3.stubs(:capture3).returns(['result', '', status])

    ProcessMessageJob.perform_now(jennifer_message.id)

    reply = Message.last
    assert_equal '(Tool use limit reached)', reply.content

    # Safety valve kicks in at agent.max_tool_rounds (default 10) — the last round breaks before execution
    assert_equal agents(:jennifer).max_tool_rounds - 1, ToolExecution.count
  end

  test 'token totals accumulate across rounds' do
    tool_use_response = build_tool_use_response(
      tool_name: 'find_availability',
      tool_id: 'toolu_03',
      input: {},
      input_tokens: 100,
      output_tokens: 50
    )
    text_response = build_text_response('Done', input_tokens: 200, output_tokens: 80)

    messages_api = stub
    messages_api.stubs(:create).returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)

    status = stub(exitstatus: 0)
    Open3.stubs(:capture3).returns(['ok', '', status])

    ProcessMessageJob.perform_now(jennifer_message.id)

    reply = Message.last
    assert_equal 300, reply.metadata['input_tokens']
    assert_equal 130, reply.metadata['output_tokens']
  end

  test 'reply includes source_message_id for idempotency' do
    stub_text_response('Hello!')

    ProcessMessageJob.perform_now(@message.id)

    reply = Message.last
    assert_equal @message.id, reply.metadata['source_message_id']
  end

  test 'retried job skips LLM call when reply already exists' do
    stub_text_response('First reply')
    ProcessMessageJob.perform_now(@message.id)

    # LLM should not be called again on retry
    Rails.configuration.anthropic_client.unstub(:messages)
    Rails.configuration.anthropic_client.expects(:messages).never

    ProcessMessageJob.perform_now(@message.id)

    # Still only one reply
    replies = @conversation.messages.where(role: 'assistant')
                                   .where("metadata->>'source_message_id' = ?", @message.id.to_s)
    assert_equal 1, replies.count
  end

  test 'delivery failure does not lose the persisted reply' do
    stub_text_response('Hello!')
    jennifer_message = messages(:alice_jennifer_hello)

    adapter = stub(send_typing: true)
    adapter.stubs(:send_reply).raises(Adapters::DeliveryError, 'Telegram down')
    Adapters::Telegram.stubs(:new).returns(adapter)
    ProcessMessageJob.stubs(:notify_failure)

    # retry_on handles the error — job doesn't raise to caller
    ProcessMessageJob.perform_now(jennifer_message.id)

    # Reply was saved despite delivery failure
    jennifer_conversation = conversations(:alice_jennifer)
    reply = jennifer_conversation.messages.where(role: 'assistant')
                                         .where("metadata->>'source_message_id' = ?", jennifer_message.id.to_s)
                                         .first
    assert_not_nil reply
    assert_equal 'Hello!', reply.content
  end

  test 'agents without agent-specific tools still get builtin tools' do
    stub_text_response('Hi there!')

    ProcessMessageJob.perform_now(@message.id)

    reply = Message.last
    assert_equal 'Hi there!', reply.content
    assert_nil reply.metadata['tool_calls']
  end

  private

  def stub_adapter
    adapter = stub(send_typing: true, send_reply: true)
    Adapters::Telegram.stubs(:new).returns(adapter)
  end

  def stub_text_response(text)
    response = build_text_response(text)
    messages_api = stub(create: response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)
  end

  def build_text_response(text, input_tokens: 100, output_tokens: 50)
    content_block = Data.define(:type, :text).new(type: :text, text: text)
    usage = Data.define(:input_tokens, :output_tokens).new(
      input_tokens: input_tokens, output_tokens: output_tokens
    )
    Data.define(:content, :usage, :model, :stop_reason).new(
      content: [content_block], usage: usage, model: 'claude-sonnet-4-5-20250929', stop_reason: :end_turn
    )
  end

  def build_tool_use_response(tool_name:, tool_id:, input:, text: '', input_tokens: 100, output_tokens: 50)
    blocks = []
    if text.present?
      blocks << Data.define(:type, :text).new(type: :text, text: text)
    end
    blocks << Data.define(:type, :id, :name, :input).new(
      type: :tool_use, id: tool_id, name: tool_name, input: input
    )
    usage = Data.define(:input_tokens, :output_tokens).new(
      input_tokens: input_tokens, output_tokens: output_tokens
    )
    Data.define(:content, :usage, :model, :stop_reason).new(
      content: blocks, usage: usage, model: 'claude-sonnet-4-5-20250929', stop_reason: :tool_use
    )
  end
end
