require 'test_helper'
require 'open3'

class Tools::ExecutorTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @tool = agent_tools(:jennifer_scheduling)
  end

  test 'build_argv splits command template and substitutes placeholders' do
    executor = Tools::Executor.new(agent_tool: @tool)
    argv = executor.build_argv({ 'attendees' => 'alice@example.com', 'duration' => '30' })
    assert_equal ['python3', 'find-availability.py', 'alice@example.com', '--duration', '30'], argv
  end

  test 'build_argv handles missing input keys gracefully' do
    executor = Tools::Executor.new(agent_tool: @tool)
    argv = executor.build_argv({ 'attendees' => 'alice@example.com' })
    # Missing {duration} keeps the key name as fallback
    assert_equal ['python3', 'find-availability.py', 'alice@example.com', '--duration', 'duration'], argv
  end

  test 'build_argv prevents shell injection via input values' do
    executor = Tools::Executor.new(agent_tool: @tool)
    argv = executor.build_argv({ 'attendees' => '$(rm -rf /)', 'duration' => '30; echo pwned' })
    # Values are literal strings in the argv array — no shell interpretation
    assert_equal ['python3', 'find-availability.py', '$(rm -rf /)', '--duration', '30; echo pwned'], argv
  end

  test 'build_env returns credentials as string hash' do
    @tool.credentials = { 'API_KEY' => 'secret', 'TIMEOUT' => 5 }
    executor = Tools::Executor.new(agent_tool: @tool)
    env = executor.build_env
    assert_equal({ 'API_KEY' => 'secret', 'TIMEOUT' => '5' }, env)
  end

  test 'build_env returns empty hash when no credentials' do
    @tool.credentials_json = nil
    executor = Tools::Executor.new(agent_tool: @tool)
    assert_equal({}, executor.build_env)
  end

  test 'resolve_working_directory uses tool working_directory when set' do
    executor = Tools::Executor.new(agent_tool: @tool)
    assert_equal '/srv/steward/skills/scheduling', executor.resolve_working_directory
  end

  test 'resolve_working_directory falls back to Rails.root' do
    @tool.working_directory = nil
    executor = Tools::Executor.new(agent_tool: @tool)
    assert_equal Rails.root.to_s, executor.resolve_working_directory
  end

  test 'call executes command and returns result' do
    @tool.command_template = 'echo hello'
    @tool.working_directory = nil
    executor = Tools::Executor.new(agent_tool: @tool)

    status = stub(exitstatus: 0)
    Open3.stubs(:capture3).returns(['hello\n', '', status])

    result = executor.call({})
    assert_equal 'hello\n', result.stdout
    assert_equal '', result.stderr
    assert_equal 0, result.exit_code
    assert_equal false, result.timed_out
  end

  test 'call handles timeout' do
    @tool.command_template = 'sleep 999'
    @tool.timeout_seconds = 1
    @tool.working_directory = nil
    executor = Tools::Executor.new(agent_tool: @tool)

    Open3.stubs(:capture3).raises(Timeout::Error)

    result = executor.call({})
    assert result.timed_out
    assert_nil result.exit_code
    assert_includes result.stderr, 'timed out'
  end

  test 'call truncates long output' do
    @tool.command_template = 'echo big'
    @tool.working_directory = nil
    executor = Tools::Executor.new(agent_tool: @tool)

    long_output = 'x' * 60_000
    status = stub(exitstatus: 0)
    Open3.stubs(:capture3).returns([long_output, '', status])

    result = executor.call({})
    assert result.stdout.length <= Tools::Executor::MAX_OUTPUT_LENGTH + 20
    assert_includes result.stdout, '... (truncated)'
  end

  test 'call passes environment variables to command' do
    @tool.command_template = 'env'
    @tool.credentials = { 'MY_SECRET' => 'val123' }
    @tool.working_directory = nil
    executor = Tools::Executor.new(agent_tool: @tool)

    status = stub(exitstatus: 0)
    Open3.expects(:capture3).with(
      { 'MY_SECRET' => 'val123' },
      'env',
      chdir: Rails.root.to_s
    ).returns(['MY_SECRET=val123\n', '', status])

    result = executor.call({})
    assert_equal 0, result.exit_code
  end

  test 'call merges extra_env into environment' do
    @tool.command_template = 'env'
    @tool.credentials = { 'TOOL_KEY' => 'from_tool' }
    @tool.working_directory = nil
    executor = Tools::Executor.new(agent_tool: @tool)

    status = stub(exitstatus: 0)
    Open3.expects(:capture3).with(
      { 'TOOL_KEY' => 'from_tool', 'XDG_CONFIG_HOME' => '/tmp/gog/1', 'GOG_KEYRING_PASSWORD' => 'pw123' },
      'env',
      chdir: Rails.root.to_s
    ).returns(['output', '', status])

    result = executor.call({}, extra_env: { 'XDG_CONFIG_HOME' => '/tmp/gog/1', 'GOG_KEYRING_PASSWORD' => 'pw123' })
    assert_equal 0, result.exit_code
  end

  test 'extra_env overrides tool credentials when keys collide' do
    @tool.command_template = 'env'
    @tool.credentials = { 'SHARED_KEY' => 'from_tool' }
    @tool.working_directory = nil
    executor = Tools::Executor.new(agent_tool: @tool)

    status = stub(exitstatus: 0)
    Open3.expects(:capture3).with(
      { 'SHARED_KEY' => 'from_principal' },
      'env',
      chdir: Rails.root.to_s
    ).returns(['output', '', status])

    result = executor.call({}, extra_env: { 'SHARED_KEY' => 'from_principal' })
    assert_equal 0, result.exit_code
  end
end
