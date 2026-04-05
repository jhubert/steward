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
    Tools::Executor.any_instance.stubs(:call).returns(
      Tools::Executor::Result.new(stdout: 'Mon 2pm, Tue 3pm', stderr: '', exit_code: 0, timed_out: false)
    )

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

    Tools::Executor.any_instance.stubs(:call).returns(
      Tools::Executor::Result.new(stdout: '', stderr: 'Connection failed', exit_code: 1, timed_out: false)
    )

    ProcessMessageJob.perform_now(jennifer_message.id)

    reply = Message.last
    assert_equal 'Sorry, there was an error checking the calendar.', reply.content

    execution = ToolExecution.last
    assert_equal 1, execution.exit_code
    assert_equal 'Connection failed', execution.error
  end

  test 'max tool rounds safety valve stops loop and asks LLM for summary' do
    # Build a response that always returns tool_use
    tool_use_response = build_tool_use_response(
      tool_name: 'search_contacts',
      tool_id: 'toolu_loop',
      input: { 'query' => 'test' },
      text: ''
    )
    # The final call (without tools) returns a helpful summary
    final_response = build_text_response('I was searching contacts but hit my limit. Try narrowing your search.')

    messages_api = stub
    # max_tool_rounds (10) tool_use responses, then 1 final text response
    s = messages_api.stubs(:create).returns(tool_use_response)
    9.times { s = s.then.returns(tool_use_response) }
    s.then.returns(final_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)

    Tools::Executor.any_instance.stubs(:call).returns(
      Tools::Executor::Result.new(stdout: 'result', stderr: '', exit_code: 0, timed_out: false)
    )

    ProcessMessageJob.perform_now(jennifer_message.id)

    reply = Message.last
    assert_equal 'I was searching contacts but hit my limit. Try narrowing your search.', reply.content

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

    Tools::Executor.any_instance.stubs(:call).returns(
      Tools::Executor::Result.new(stdout: 'ok', stderr: '', exit_code: 0, timed_out: false)
    )

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

  test 'tool execution injects per-user gog env when principal has credentials' do
    principal = agent_principals(:jennifer_alice)
    principal.credentials = { "gog_keyring_password" => "secret_pw" }
    principal.save!

    tool_use_response = build_tool_use_response(
      tool_name: 'find_availability',
      tool_id: 'toolu_gog',
      input: { 'attendees' => 'alice@example.com' }
    )
    text_response = build_text_response('Done')

    messages_api = stub
    messages_api.stubs(:create).returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)
    user_id = conversations(:alice_jennifer).user.id
    expected_gog_dir = Rails.root.join("data", "gog", user_id.to_s).to_s

    captured_extra_env = nil
    executor_spy = Object.new
    executor_spy.define_singleton_method(:call) do |input, extra_env: {}|
      captured_extra_env = extra_env
      Tools::Executor::Result.new(stdout: 'ok', stderr: '', exit_code: 0, timed_out: false)
    end
    Tools::Executor.stubs(:new).returns(executor_spy)

    ProcessMessageJob.perform_now(jennifer_message.id)

    assert_equal expected_gog_dir, captured_extra_env['XDG_CONFIG_HOME']
    assert_equal 'secret_pw', captured_extra_env['GOG_KEYRING_PASSWORD']
    assert_equal 'file', captured_extra_env['GOG_KEYRING_BACKEND']
  end

  test 'tool execution does not inject gog env when principal has no credentials' do
    tool_use_response = build_tool_use_response(
      tool_name: 'find_availability',
      tool_id: 'toolu_no_gog',
      input: { 'attendees' => 'alice@example.com' }
    )
    text_response = build_text_response('Done')

    messages_api = stub
    messages_api.stubs(:create).returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)

    captured_extra_env = nil
    executor_spy = Object.new
    executor_spy.define_singleton_method(:call) do |input, extra_env: {}|
      captured_extra_env = extra_env
      Tools::Executor::Result.new(stdout: 'ok', stderr: '', exit_code: 0, timed_out: false)
    end
    Tools::Executor.stubs(:new).returns(executor_spy)

    ProcessMessageJob.perform_now(jennifer_message.id)

    assert_not_includes captured_extra_env.keys, 'GOG_KEYRING_PASSWORD'
    assert_not_includes captured_extra_env.keys, 'XDG_CONFIG_HOME'
  end

  test 'google_setup check action reports unconfigured for user without credentials' do
    tool_use_response = build_tool_use_response(
      tool_name: 'google_setup',
      tool_id: 'toolu_gs_check',
      input: { 'action' => 'check' }
    )
    text_response = build_text_response('Google is not configured yet.')

    messages_api = stub
    messages_api.stubs(:create).returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)
    ProcessMessageJob.perform_now(jennifer_message.id)

    reply = Message.last
    assert_equal 'Google is not configured yet.', reply.content
  end

  test 'google_setup check action reports configured when credentials exist' do
    principal = agent_principals(:jennifer_alice)
    principal.credentials = { "gog_keyring_password" => "secret" }
    principal.save!

    tool_use_response = build_tool_use_response(
      tool_name: 'google_setup',
      tool_id: 'toolu_gs_check2',
      input: { 'action' => 'check' }
    )
    text_response = build_text_response('Google is configured!')

    messages_api = stub
    messages_api.stubs(:create).returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)
    ProcessMessageJob.perform_now(jennifer_message.id)

    reply = Message.last
    assert_equal 'Google is configured!', reply.content
  end

  test 'google_setup generate_link action returns a signed URL' do
    tool_use_response = build_tool_use_response(
      tool_name: 'google_setup',
      tool_id: 'toolu_gs_link',
      input: { 'action' => 'generate_link' }
    )
    text_response = build_text_response('Here is your setup link.')

    messages_api = stub
    # Capture the tool result to verify it contains a URL
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)
    ProcessMessageJob.perform_now(jennifer_message.id)

    # The tool result should contain a setup URL
    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match %r{setup/google/}, tool_content[:content]
  end

  test 'google_setup returns error for non-principal user' do
    tool_use_response = build_tool_use_response(
      tool_name: 'google_setup',
      tool_id: 'toolu_gs_noprincipal',
      input: { 'action' => 'check' }
    )
    text_response = build_text_response('Sorry, you need to be a principal.')

    messages_api = stub
    messages_api.stubs(:create).returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    # alice_telegram is on the steward agent (no principals)
    ProcessMessageJob.perform_now(@message.id)

    reply = Message.last
    assert_equal 'Sorry, you need to be a principal.', reply.content
  end

  test 'download_file virtual tool downloads successfully' do
    tool_use_response = build_tool_use_response(
      tool_name: 'download_file',
      tool_id: 'toolu_dl_ok',
      input: { 'url' => 'https://example.com/report.pdf' }
    )
    text_response = build_text_response('File downloaded.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    downloader_result = Tools::FileDownloader::Result.new(success: true, path: "/tmp/test.pdf", error: nil, size: 1024)
    Tools::FileDownloader.any_instance.stubs(:call).returns(downloader_result)

    jennifer_message = messages(:alice_jennifer_hello)
    ProcessMessageJob.perform_now(jennifer_message.id)

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/downloaded successfully/, tool_content[:content])
    assert_match(/1024 bytes/, tool_content[:content])
  end

  test 'download_file virtual tool handles failure' do
    tool_use_response = build_tool_use_response(
      tool_name: 'download_file',
      tool_id: 'toolu_dl_fail',
      input: { 'url' => 'https://example.com/missing.txt' }
    )
    text_response = build_text_response('Download failed.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    downloader_result = Tools::FileDownloader::Result.new(success: false, path: nil, error: "HTTP 404", size: nil)
    Tools::FileDownloader.any_instance.stubs(:call).returns(downloader_result)

    jennifer_message = messages(:alice_jennifer_hello)
    ProcessMessageJob.perform_now(jennifer_message.id)

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/Download failed.*HTTP 404/, tool_content[:content])
  end

  test 'schedule_task virtual tool creates a scheduled task' do
    tool_use_response = build_tool_use_response(
      tool_name: 'schedule_task',
      tool_id: 'toolu_sched',
      input: { 'description' => 'Daily standup', 'run_at' => 1.hour.from_now.iso8601, 'interval' => 'daily' }
    )
    text_response = build_text_response('Task scheduled!')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)

    assert_difference 'ScheduledTask.count', 1 do
      ProcessMessageJob.perform_now(jennifer_message.id)
    end

    task = ScheduledTask.last
    assert_equal 'Daily standup', task.description
    assert_equal 86_400, task.interval_seconds
    assert task.enabled?

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/Task scheduled/, tool_content[:content])
  end

  test 'schedule_task rejects Steward agent self-scheduling' do
    tool_use_response = build_tool_use_response(
      tool_name: 'schedule_task',
      tool_id: 'toolu_sched_steward',
      input: {
        'description' => 'Daily check-in',
        'run_at' => 1.hour.from_now.iso8601,
        'interval' => 'daily'
      }
    )
    text_response = build_text_response('Cannot schedule.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    # Use the Steward agent conversation (alice_telegram)
    steward_message = messages(:alice_hello)

    assert_no_difference 'ScheduledTask.count' do
      ProcessMessageJob.perform_now(steward_message.id)
    end

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/platform coordinator/, tool_content[:content])
    assert_match(/cannot create scheduled tasks/, tool_content[:content])
  end

  test 'list_scheduled_tasks virtual tool returns task list' do
    tool_use_response = build_tool_use_response(
      tool_name: 'list_scheduled_tasks',
      tool_id: 'toolu_list',
      input: {}
    )
    text_response = build_text_response('Here are your tasks.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)
    ProcessMessageJob.perform_now(jennifer_message.id)

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/standup/, tool_content[:content])
  end

  test 'cancel_scheduled_task virtual tool cancels a task' do
    task = scheduled_tasks(:alice_daily_standup)

    tool_use_response = build_tool_use_response(
      tool_name: 'cancel_scheduled_task',
      tool_id: 'toolu_cancel',
      input: { 'task_id' => task.id }
    )
    text_response = build_text_response('Task cancelled.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)
    ProcessMessageJob.perform_now(jennifer_message.id)

    task.reload
    assert_not task.enabled?

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/cancelled/, tool_content[:content])
  end

  test 'cancel_scheduled_task returns error for different user' do
    # bob_disabled_task belongs to bob, not alice
    task = scheduled_tasks(:bob_disabled_task)

    tool_use_response = build_tool_use_response(
      tool_name: 'cancel_scheduled_task',
      tool_id: 'toolu_cancel_wrong',
      input: { 'task_id' => task.id }
    )
    text_response = build_text_response('Could not find that task.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)
    ProcessMessageJob.perform_now(jennifer_message.id)

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/not found/, tool_content[:content])
  end

  test 'schedule_task with tool_name creates direct execution task' do
    tool_use_response = build_tool_use_response(
      tool_name: 'schedule_task',
      tool_id: 'toolu_sched_direct',
      input: {
        'description' => 'Check mail every 10 min',
        'run_at' => 1.hour.from_now.iso8601,
        'interval' => 'custom',
        'interval_seconds' => 600,
        'tool_name' => 'find_availability',
        'tool_input' => { 'attendees' => 'alice@example.com' }
      }
    )
    text_response = build_text_response('Direct task scheduled!')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)

    assert_difference 'ScheduledTask.count', 1 do
      ProcessMessageJob.perform_now(jennifer_message.id)
    end

    task = ScheduledTask.last
    assert_equal 'Check mail every 10 min', task.description
    assert_equal 600, task.interval_seconds
    assert task.direct_execution?
    assert_equal agent_tools(:jennifer_scheduling), task.agent_tool
    assert_equal({ 'attendees' => 'alice@example.com' }, task.tool_input)
    assert_equal users(:alice), task.user

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/Task scheduled/, tool_content[:content])
    assert_match(/direct: find_availability/, tool_content[:content])
  end

  test 'schedule_task rejects virtual tool names' do
    tool_use_response = build_tool_use_response(
      tool_name: 'schedule_task',
      tool_id: 'toolu_sched_virtual',
      input: {
        'description' => 'Save notes periodically',
        'run_at' => 1.hour.from_now.iso8601,
        'tool_name' => 'save_note',
        'tool_input' => { 'content' => 'test' }
      }
    )
    text_response = build_text_response('Cannot schedule that.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)

    assert_no_difference 'ScheduledTask.count' do
      ProcessMessageJob.perform_now(jennifer_message.id)
    end

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/built-in tool/, tool_content[:content])
  end

  test 'schedule_task rejects unknown tool_name' do
    tool_use_response = build_tool_use_response(
      tool_name: 'schedule_task',
      tool_id: 'toolu_sched_unknown',
      input: {
        'description' => 'Run nonexistent tool',
        'run_at' => 1.hour.from_now.iso8601,
        'tool_name' => 'nonexistent_tool'
      }
    )
    text_response = build_text_response('Tool not found.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)

    assert_no_difference 'ScheduledTask.count' do
      ProcessMessageJob.perform_now(jennifer_message.id)
    end

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/Unknown tool/, tool_content[:content])
  end

  test 'session break triggers inline compaction when gap exceeds threshold' do
    # Move all existing fixture messages to 10 hours ago
    @conversation.messages.update_all(created_at: 10.hours.ago)

    new_msg = @conversation.messages.create!(
      workspace: workspaces(:default), user: users(:alice),
      role: 'user', content: 'Good morning!',
      created_at: Time.current
    )

    # The anthropic client will be called twice: once for summarization, once for the reply
    summary_content = Data.define(:type, :text).new(type: :text, text: 'Previous session summary')
    summary_usage = Data.define(:input_tokens, :output_tokens).new(input_tokens: 50, output_tokens: 30)
    summary_response = Data.define(:content, :usage, :model, :stop_reason).new(
      content: [summary_content], usage: summary_usage, model: 'claude-sonnet-4-5-20250929', stop_reason: :end_turn
    )

    text_content = Data.define(:type, :text).new(type: :text, text: 'Good morning!')
    text_usage = Data.define(:input_tokens, :output_tokens).new(input_tokens: 100, output_tokens: 50)
    text_response = Data.define(:content, :usage, :model, :stop_reason).new(
      content: [text_content], usage: text_usage, model: 'claude-sonnet-4-5-20250929', stop_reason: :end_turn
    )

    messages_api = stub
    messages_api.stubs(:create).returns(summary_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    ProcessMessageJob.perform_now(new_msg.id)

    state = @conversation.ensure_state!.reload
    assert_includes state.summary, 'Previous session summary'
    assert_includes state.summary, 'Session break'
    assert state.summarized_through_message_id.present?
  end

  test 'background channel processes message without adapter delivery' do
    agent = agents(:jennifer)
    user = users(:alice)

    conversation = Conversation.find_or_start(
      user: user,
      agent: agent,
      channel: "background",
      external_thread_key: "background:#{agent.id}:#{user.id}"
    )

    message = conversation.messages.create!(
      workspace: workspaces(:default),
      user: user,
      role: 'user',
      content: 'New email from bob@example.com'
    )

    stub_text_response('I will forward this to Alice via Telegram.')

    # Background adapter should never attempt Telegram delivery
    Adapters::Telegram.expects(:new).never

    assert_difference 'Message.count', 1 do
      ProcessMessageJob.perform_now(message.id)
    end

    reply = Message.last
    assert_equal 'assistant', reply.role
    assert_equal 'I will forward this to Alice via Telegram.', reply.content
  end

  test 'send_message delivers to Telegram conversation from background' do
    agent = agents(:jennifer)
    user = users(:alice)

    bg_conversation = Conversation.find_or_start(
      user: user, agent: agent, channel: "background",
      external_thread_key: "background:#{agent.id}:#{user.id}"
    )
    bg_message = bg_conversation.messages.create!(
      workspace: workspaces(:default), user: user,
      role: 'user', content: 'New event received'
    )

    tool_use_response = build_tool_use_response(
      tool_name: 'send_message',
      tool_id: 'toolu_send',
      input: { 'text' => 'You have a new event!' }
    )
    text_response = build_text_response('Done, notified the user.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    telegram_adapter = stub(send_typing: true, send_reply: true)
    Adapters::Telegram.stubs(:new).returns(telegram_adapter)

    telegram_conv = conversations(:alice_jennifer)
    initial_msg_count = telegram_conv.messages.count

    ProcessMessageJob.perform_now(bg_message.id)

    # Message was created in the Telegram conversation
    assert_equal initial_msg_count + 1, telegram_conv.messages.reload.count
    sent_msg = telegram_conv.messages.last
    assert_equal 'assistant', sent_msg.role
    assert_equal 'You have a new event!', sent_msg.content
    assert_equal 'background', sent_msg.metadata['source']

    # Adapter was called to deliver
    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/delivered/, tool_content[:content])
  end

  test 'send_message stores context in metadata when provided' do
    agent = agents(:jennifer)
    user = users(:alice)

    bg_conversation = Conversation.find_or_start(
      user: user, agent: agent, channel: "background",
      external_thread_key: "background:#{agent.id}:#{user.id}"
    )
    bg_message = bg_conversation.messages.create!(
      workspace: workspaces(:default), user: user,
      role: 'user', content: 'New event received'
    )

    tool_use_response = build_tool_use_response(
      tool_name: 'send_message',
      tool_id: 'toolu_send_ctx',
      input: { 'text' => 'You have a dinner invitation!', 'context' => 'Found dinner invitation email from Sarah for Friday' }
    )
    text_response = build_text_response('Done, notified the user.')

    messages_api = stub
    messages_api.stubs(:create).returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    telegram_adapter = stub(send_typing: true, send_reply: true)
    Adapters::Telegram.stubs(:new).returns(telegram_adapter)

    ProcessMessageJob.perform_now(bg_message.id)

    telegram_conv = conversations(:alice_jennifer)
    sent_msg = telegram_conv.messages.where(role: 'assistant').order(:id).last
    assert_equal 'background', sent_msg.metadata['source']
    assert_equal 'Found dinner invitation email from Sarah for Friday', sent_msg.metadata['background_context']
  end

  test 'send_message returns error when no Telegram conversation exists' do
    agent = agents(:steward)
    user = users(:bob)

    bg_conversation = Conversation.find_or_start(
      user: user, agent: agent, channel: "background",
      external_thread_key: "background:#{agent.id}:#{user.id}"
    )
    bg_message = bg_conversation.messages.create!(
      workspace: workspaces(:default), user: user,
      role: 'user', content: 'Event for bob'
    )

    tool_use_response = build_tool_use_response(
      tool_name: 'send_message',
      tool_id: 'toolu_send_fail',
      input: { 'text' => 'Hello Bob!' }
    )
    text_response = build_text_response('Could not deliver message.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    ProcessMessageJob.perform_now(bg_message.id)

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/No Telegram or email conversation/, tool_content[:content])
  end

  test 'remember virtual tool creates a memory item' do
    tool_use_response = build_tool_use_response(
      tool_name: 'remember',
      tool_id: 'toolu_remember',
      input: { 'content' => 'Prefers morning meetings', 'category' => 'preference' }
    )
    text_response = build_text_response('Got it, I will remember that.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)

    assert_difference 'MemoryItem.count', 1 do
      ProcessMessageJob.perform_now(jennifer_message.id)
    end

    item = MemoryItem.last
    assert_equal 'preference', item.category
    assert_equal 'Prefers morning meetings', item.content
    assert_equal users(:alice), item.user
    assert_equal agents(:jennifer), item.agent
    assert_equal conversations(:alice_jennifer), item.conversation
    assert_equal 'agent_tool', item.metadata['source']

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/Remembered.*preference.*Prefers morning meetings/, tool_content[:content])
  end

  test 'remember virtual tool rejects invalid category' do
    tool_use_response = build_tool_use_response(
      tool_name: 'remember',
      tool_id: 'toolu_remember_bad',
      input: { 'content' => 'Some note', 'category' => 'bogus' }
    )
    text_response = build_text_response('That did not work.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)

    assert_no_difference 'MemoryItem.count' do
      ProcessMessageJob.perform_now(jennifer_message.id)
    end

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/Invalid category/, tool_content[:content])
  end

  test 'remember virtual tool rejects blank content' do
    tool_use_response = build_tool_use_response(
      tool_name: 'remember',
      tool_id: 'toolu_remember_blank',
      input: { 'content' => '', 'category' => 'fact' }
    )
    text_response = build_text_response('Missing content.')

    messages_api = stub
    messages_api.stubs(:create).returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)

    assert_no_difference 'MemoryItem.count' do
      ProcessMessageJob.perform_now(jennifer_message.id)
    end
  end

  test 'create_skill virtual tool creates skill files and reloads registry' do
    tool_use_response = build_tool_use_response(
      tool_name: 'create_skill',
      tool_id: 'toolu_skill_ok',
      input: {
        'skill_name' => 'test-created-skill',
        'description' => 'A test skill created by the virtual tool.',
        'instructions' => "# Test Skill\n\nDo the test thing."
      }
    )
    text_response = build_text_response('Skill created!')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)
    ProcessMessageJob.perform_now(jennifer_message.id)

    # Verify files were created
    skill_dir = Rails.root.join('skills', 'test-created-skill')
    assert skill_dir.exist?, 'Skill directory should exist'
    assert skill_dir.join('SKILL.md').exist?, 'SKILL.md should exist'

    content = skill_dir.join('SKILL.md').read
    assert_match(/name: test-created-skill/, content)
    assert_match(/A test skill created by the virtual tool/, content)
    assert_match(/# Test Skill/, content)

    # Verify registry was reloaded
    skill = Skills::Registry.instance.find('test-created-skill')
    assert_not_nil skill, 'Registry should have the new skill'

    # Verify tool result
    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/created successfully/, tool_content[:content])
  ensure
    FileUtils.rm_rf(Rails.root.join('skills', 'test-created-skill'))
    Skills::Registry.instance.reload!
  end

  test 'create_skill with tools_yaml and scripts creates all files' do
    tools_yaml = <<~YAML
      tools:
        - name: test_tool
          description: "A test tool"
          input_schema:
            type: object
            properties:
              query:
                type: string
          command_template: "python3 scripts/test.py {query}"
          timeout_seconds: 15
    YAML

    tool_use_response = build_tool_use_response(
      tool_name: 'create_skill',
      tool_id: 'toolu_skill_full',
      input: {
        'skill_name' => 'test-full-skill',
        'description' => 'A full skill with tools and scripts.',
        'instructions' => '# Full Skill',
        'tools_yaml' => tools_yaml,
        'scripts' => { 'test.py' => "#!/usr/bin/env python3\nprint('hello')" }
      }
    )
    text_response = build_text_response('Done!')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)
    ProcessMessageJob.perform_now(jennifer_message.id)

    skill_dir = Rails.root.join('skills', 'test-full-skill')
    assert skill_dir.join('SKILL.md').exist?
    assert skill_dir.join('tools.yml').exist?
    assert skill_dir.join('scripts', 'test.py').exist?
    assert File.executable?(skill_dir.join('scripts', 'test.py'))

    # Verify tools.yml content
    tools_data = YAML.safe_load(skill_dir.join('tools.yml').read)
    assert_equal 'test_tool', tools_data['tools'].first['name']

    # Verify registry loaded tools
    skill = Skills::Registry.instance.find('test-full-skill')
    assert_equal 1, skill.tool_definitions.size
    assert_equal 'test_tool', skill.tool_definitions.first[:name]

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/SKILL.md/, tool_content[:content])
    assert_match(/tools.yml/, tool_content[:content])
    assert_match(/scripts\/test.py/, tool_content[:content])
  ensure
    FileUtils.rm_rf(Rails.root.join('skills', 'test-full-skill'))
    Skills::Registry.instance.reload!
  end

  test 'create_skill rejects invalid skill name' do
    tool_use_response = build_tool_use_response(
      tool_name: 'create_skill',
      tool_id: 'toolu_skill_bad_name',
      input: {
        'skill_name' => '../etc/evil',
        'description' => 'Malicious skill',
        'instructions' => '# Evil'
      }
    )
    text_response = build_text_response('Invalid name.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)
    ProcessMessageJob.perform_now(jennifer_message.id)

    # Verify no directory was created
    assert_not Rails.root.join('skills', '..', 'etc', 'evil').exist?

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/must be kebab-case/, tool_content[:content])
  end

  test 'create_skill rejects invalid script filenames' do
    tool_use_response = build_tool_use_response(
      tool_name: 'create_skill',
      tool_id: 'toolu_skill_bad_script',
      input: {
        'skill_name' => 'test-bad-scripts',
        'description' => 'Bad scripts',
        'instructions' => '# Bad',
        'scripts' => { '../evil.sh' => '#!/bin/bash\nrm -rf /' }
      }
    )
    text_response = build_text_response('Bad filename.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)
    ProcessMessageJob.perform_now(jennifer_message.id)

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/Invalid script filename/, tool_content[:content])
  ensure
    FileUtils.rm_rf(Rails.root.join('skills', 'test-bad-scripts'))
    Skills::Registry.instance.reload!
  end

  test 'create_skill with enable_for enables skill on target agent' do
    tool_use_response = build_tool_use_response(
      tool_name: 'create_skill',
      tool_id: 'toolu_skill_enable',
      input: {
        'skill_name' => 'test-enable-skill',
        'description' => 'Skill to be auto-enabled.',
        'instructions' => '# Auto-enabled',
        'tools_yaml' => "tools:\n  - name: test_enable_tool\n    description: \"Test\"\n    input_schema:\n      type: object\n      properties:\n        x:\n          type: string\n    command_template: \"echo {x}\"\n    timeout_seconds: 10",
        'enable_for' => 'Jennifer'
      }
    )
    text_response = build_text_response('Enabled!')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)
    jennifer = agents(:jennifer)

    ProcessMessageJob.perform_now(jennifer_message.id)

    # Verify tool was created on the agent
    assert jennifer.agent_tools.exists?(name: 'test_enable_tool'), 'Agent tool should have been created'

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/Enabled for agent: Jennifer/, tool_content[:content])
  ensure
    agents(:jennifer).agent_tools.where(name: 'test_enable_tool').destroy_all
    FileUtils.rm_rf(Rails.root.join('skills', 'test-enable-skill'))
    Skills::Registry.instance.reload!
  end

  test 'create_skill with invalid tools_yaml returns error' do
    tool_use_response = build_tool_use_response(
      tool_name: 'create_skill',
      tool_id: 'toolu_skill_bad_yaml',
      input: {
        'skill_name' => 'test-bad-yaml',
        'description' => 'Bad YAML',
        'instructions' => '# Bad',
        'tools_yaml' => "not: valid: yaml: [["
      }
    )
    text_response = build_text_response('Invalid YAML.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)
    ProcessMessageJob.perform_now(jennifer_message.id)

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/Invalid YAML|must have a top-level/, tool_content[:content])
  ensure
    FileUtils.rm_rf(Rails.root.join('skills', 'test-bad-yaml'))
    Skills::Registry.instance.reload!
  end

  # --- recall virtual tool tests ---

  test 'recall virtual tool returns formatted memory results' do
    tool_use_response = build_tool_use_response(
      tool_name: 'recall',
      tool_id: 'toolu_recall',
      input: { 'query' => 'morning meetings' }
    )
    text_response = build_text_response('You prefer morning meetings.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)
    Rails.configuration.stubs(:openai_client).returns(nil)

    jennifer_message = messages(:alice_jennifer_hello)
    ProcessMessageJob.perform_now(jennifer_message.id)

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/morning meetings/, tool_content[:content])
    assert_match(/preference/, tool_content[:content])
    assert_match(/Found \d+ memor/, tool_content[:content])
  end

  test 'recall virtual tool filters by category' do
    tool_use_response = build_tool_use_response(
      tool_name: 'recall',
      tool_id: 'toolu_recall_cat',
      input: { 'query' => 'Alice', 'category' => 'fact' }
    )
    text_response = build_text_response('Found facts.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)
    Rails.configuration.stubs(:openai_client).returns(nil)

    jennifer_message = messages(:alice_jennifer_hello)
    ProcessMessageJob.perform_now(jennifer_message.id)

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/fact/, tool_content[:content])
    assert_match(/Toronto/, tool_content[:content])
    # Should NOT include the preference about morning meetings
    assert_no_match(/morning meetings/, tool_content[:content])
  end

  test 'recall in principal mode searches across all principals' do
    tool_use_response = build_tool_use_response(
      tool_name: 'recall',
      tool_id: 'toolu_recall_principal',
      input: { 'query' => 'operations team' }
    )
    text_response = build_text_response('Bob manages the operations team.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)
    Rails.configuration.stubs(:openai_client).returns(nil)

    # Jennifer is a principal-mode agent — search should find Bob's memories too
    jennifer_message = messages(:alice_jennifer_hello)
    ProcessMessageJob.perform_now(jennifer_message.id)

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/operations team/, tool_content[:content])
    assert_match(/Bob's memory/, tool_content[:content])
  end

  test 'recall returns no-results message when nothing matches' do
    tool_use_response = build_tool_use_response(
      tool_name: 'recall',
      tool_id: 'toolu_recall_empty',
      input: { 'query' => 'xyznonexistent' }
    )
    text_response = build_text_response('I don\'t recall that.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)
    Rails.configuration.stubs(:openai_client).returns(nil)

    jennifer_message = messages(:alice_jennifer_hello)
    ProcessMessageJob.perform_now(jennifer_message.id)

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/No memories found/, tool_content[:content])
  end

  # --- read_transcript virtual tool tests ---

  test 'read_transcript reads messages from current conversation' do
    tool_use_response = build_tool_use_response(
      tool_name: 'read_transcript',
      tool_id: 'toolu_transcript',
      input: {}
    )
    text_response = build_text_response('Here is the transcript.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)
    ProcessMessageJob.perform_now(jennifer_message.id)

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/Transcript from conversation/, tool_content[:content])
    assert_match(/what's on the agenda/, tool_content[:content])
  end

  test 'read_transcript reads from a specific conversation belonging to the same user' do
    # Alice reads from her steward conversation while talking to Jennifer
    target_conv = conversations(:alice_telegram)

    tool_use_response = build_tool_use_response(
      tool_name: 'read_transcript',
      tool_id: 'toolu_transcript_specific',
      input: { 'conversation_id' => target_conv.id }
    )
    text_response = build_text_response('Found messages.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)
    ProcessMessageJob.perform_now(jennifer_message.id)

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/Transcript from conversation #{target_conv.id}/, tool_content[:content])
    assert_match(/Hello, Steward/, tool_content[:content])
  end

  test 'read_transcript rejects cross-user conversation access' do
    # Alice tries to read Bob's conversation
    bob_conv = conversations(:bob_jennifer)

    tool_use_response = build_tool_use_response(
      tool_name: 'read_transcript',
      tool_id: 'toolu_transcript_denied',
      input: { 'conversation_id' => bob_conv.id }
    )
    text_response = build_text_response('Access denied.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)
    ProcessMessageJob.perform_now(jennifer_message.id)

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/not found or access denied/, tool_content[:content])
  end

  test 'read_transcript with date filters returns filtered messages' do
    # Set message timestamps to known values
    msg = messages(:alice_jennifer_hello)
    msg.update_column(:created_at, Time.parse('2025-06-15T10:00:00Z'))
    messages(:jennifer_reply_alice).update_column(:created_at, Time.parse('2025-06-15T10:01:00Z'))

    tool_use_response = build_tool_use_response(
      tool_name: 'read_transcript',
      tool_id: 'toolu_transcript_date',
      input: { 'after' => '2025-06-15T09:59:00Z', 'before' => '2025-06-15T10:02:00Z' }
    )
    text_response = build_text_response('Filtered transcript.')

    messages_api = stub
    captured_tool_results = nil
    messages_api.stubs(:create).with { |**params|
      user_msgs = params[:messages]&.select { |m| m[:role] == 'user' && m[:content].is_a?(Array) }
      if user_msgs&.any?
        captured_tool_results = user_msgs.last[:content]
      end
      true
    }.returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    jennifer_message = messages(:alice_jennifer_hello)
    ProcessMessageJob.perform_now(jennifer_message.id)

    assert captured_tool_results
    tool_content = captured_tool_results.find { |r| r[:type] == 'tool_result' }
    assert_match(/Transcript from conversation/, tool_content[:content])
  end

  test 'agents without agent-specific tools still get builtin tools' do
    stub_text_response('Hi there!')

    ProcessMessageJob.perform_now(@message.id)

    reply = Message.last
    assert_equal 'Hi there!', reply.content
    assert_nil reply.metadata['tool_calls']
  end

  # --- consult_agent virtual tool tests ---

  test 'consult_agent returns response from target agent' do
    jennifer_message = messages(:alice_jennifer_hello)

    # First API call: agent uses consult_agent tool
    tool_use_response = build_tool_use_response(
      tool_name: 'consult_agent',
      tool_id: 'toolu_consult_01',
      input: { 'agent_name' => 'Markus', 'question' => 'What are the tax implications of this deal?' }
    )
    # Second API call: the consultation to Markus
    consultation_response = build_text_response('Based on current tax law, the deal would trigger capital gains of approximately 15%.')
    # Third API call: Jennifer's final reply incorporating the consultation
    final_response = build_text_response('I checked with Markus — the deal would trigger about 15% capital gains tax.')

    messages_api = stub
    messages_api.stubs(:create)
      .returns(tool_use_response)
      .then.returns(consultation_response)
      .then.returns(final_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    ProcessMessageJob.perform_now(jennifer_message.id)

    reply = Message.last
    assert_equal 'I checked with Markus — the deal would trigger about 15% capital gains tax.', reply.content
    assert reply.metadata['tool_calls'].present?
    assert_equal 'consult_agent', reply.metadata['tool_calls'].first['name']
  end

  test 'consult_agent with unknown agent name shows available agents' do
    jennifer_message = messages(:alice_jennifer_hello)

    tool_use_response = build_tool_use_response(
      tool_name: 'consult_agent',
      tool_id: 'toolu_consult_02',
      input: { 'agent_name' => 'NonexistentAgent', 'question' => 'Hello?' }
    )
    text_response = build_text_response("I couldn't find that agent.")

    messages_api = stub
    messages_api.stubs(:create).returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    ProcessMessageJob.perform_now(jennifer_message.id)

    # The tool result should have mentioned available agents — check the reply exists
    reply = Message.last
    assert_equal "I couldn't find that agent.", reply.content
  end

  test 'consult_agent fails for non-principal user' do
    # Create a user in the default workspace who is NOT a principal of jennifer
    outsider = User.create!(workspace: workspaces(:default), name: "Outsider", external_ids: { "telegram_chat_id" => "888888" })
    outsider_conv = Conversation.create!(
      workspace: workspaces(:default),
      user: outsider,
      agent: agents(:jennifer),
      channel: 'telegram',
      external_thread_key: '888888'
    )
    outsider_msg = outsider_conv.messages.create!(
      workspace: workspaces(:default),
      user: outsider,
      role: 'user',
      content: 'Consult Markus for me',
      metadata: {}
    )

    tool_use_response = build_tool_use_response(
      tool_name: 'consult_agent',
      tool_id: 'toolu_consult_03',
      input: { 'agent_name' => 'Markus', 'question' => 'What about taxes?' }
    )
    text_response = build_text_response('Sorry, I cannot do that.')

    messages_api = stub
    messages_api.stubs(:create).returns(tool_use_response).then.returns(text_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)

    ProcessMessageJob.perform_now(outsider_msg.id)

    reply = Message.last
    assert_equal 'Sorry, I cannot do that.', reply.content
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
