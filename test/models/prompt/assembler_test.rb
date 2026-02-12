require 'test_helper'

class Prompt::AssemblerTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @conversation = conversations(:alice_telegram)
    @conversation.ensure_state!
  end

  test 'call returns messages array with system message' do
    messages = Prompt::Assembler.new(@conversation).call

    assert_instance_of Array, messages
    assert_equal 'system', messages.first[:role]
    assert_includes messages.first[:content], 'Steward'
  end

  test 'includes conversation history' do
    messages = Prompt::Assembler.new(@conversation).call

    history_roles = messages[1..].map { |m| m[:role] }
    assert_includes history_roles, 'user'
    assert_includes history_roles, 'assistant'
  end

  test 'includes summary in system message when present' do
    @conversation.state.update!(summary: 'Alice asked about the weather.')

    messages = Prompt::Assembler.new(@conversation).call
    assert_includes messages.first[:content], 'Alice asked about the weather.'
  end

  test 'includes pinned facts when present' do
    @conversation.state.update!(pinned_facts: ['Alice prefers concise answers'])

    messages = Prompt::Assembler.new(@conversation).call
    assert_includes messages.first[:content], 'Alice prefers concise answers'
  end
end
