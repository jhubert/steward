require 'test_helper'

class AgentToolTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @tool = agent_tools(:jennifer_scheduling)
  end

  test 'valid tool passes validations' do
    assert @tool.valid?
  end

  test 'name must be present' do
    @tool.name = nil
    assert_not @tool.valid?
  end

  test 'name must be lowercase snake_case' do
    @tool.name = 'FindAvailability'
    assert_not @tool.valid?
    assert_includes @tool.errors[:name], 'must be lowercase snake_case'
  end

  test 'name allows valid snake_case formats' do
    @tool.name = 'find_availability_v2'
    assert @tool.valid?
  end

  test 'name must be unique per workspace and agent' do
    duplicate = @tool.dup
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:name], 'has already been taken'
  end

  test 'description must be present' do
    @tool.description = nil
    assert_not @tool.valid?
  end

  test 'command_template must be present' do
    @tool.command_template = nil
    assert_not @tool.valid?
  end

  test 'timeout_seconds must be between 1 and 300' do
    @tool.timeout_seconds = 0
    assert_not @tool.valid?

    @tool.timeout_seconds = 301
    assert_not @tool.valid?

    @tool.timeout_seconds = 1
    assert @tool.valid?

    @tool.timeout_seconds = 300
    assert @tool.valid?
  end

  test 'enabled scope returns only enabled tools' do
    enabled = AgentTool.enabled
    assert_includes enabled, agent_tools(:jennifer_scheduling)
    assert_includes enabled, agent_tools(:jennifer_moxie)
    assert_not_includes enabled, agent_tools(:jennifer_disabled)
  end

  test 'to_anthropic_tool returns correct format' do
    result = @tool.to_anthropic_tool
    assert_equal 'find_availability', result[:name]
    assert_equal 'Find available meeting slots for given attendees', result[:description]
    assert_equal 'object', result[:input_schema]['type']
    assert result[:input_schema]['properties'].key?('attendees')
  end

  test 'credentials returns parsed JSON hash' do
    @tool.credentials_json = '{"MOXIE_API_KEY": "secret123"}'
    result = @tool.credentials
    assert_equal({ 'MOXIE_API_KEY' => 'secret123' }, result)
  end

  test 'credentials returns empty hash when nil' do
    @tool.credentials_json = nil
    assert_equal({}, @tool.credentials)
  end

  test 'credentials returns empty hash for malformed JSON' do
    @tool.credentials_json = 'not json'
    assert_equal({}, @tool.credentials)
  end

  test 'credentials= sets from hash' do
    @tool.credentials = { 'API_KEY' => 'test' }
    assert_equal({ 'API_KEY' => 'test' }, @tool.credentials)
  end

  test 'credentials= clears when nil' do
    @tool.credentials = nil
    assert_nil @tool.credentials_json
  end

  test 'belongs to agent' do
    assert_equal agents(:jennifer), @tool.agent
  end

  test 'is workspace scoped' do
    as_workspace(:other)
    assert_empty AgentTool.all
  end
end
