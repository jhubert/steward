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

  test 'includes Layer P for principal-mode agents' do
    conversation = conversations(:alice_jennifer)
    conversation.ensure_state!

    messages = Prompt::Assembler.new(conversation).call
    system_content = messages.first[:content]

    assert_includes system_content, 'Current Speaker'
    assert_includes system_content, 'Alice (CEO)'
  end

  test 'omits Layer P for non-principal agents' do
    messages = Prompt::Assembler.new(@conversation).call
    system_content = messages.first[:content]

    assert_not_includes system_content, 'Current Speaker'
    assert_not_includes system_content, 'Your Principals'
  end

  test 'includes Layer D when incoming_message is set' do
    # Create a memory item that matches the query
    MemoryItem.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      conversation: @conversation,
      category: 'fact',
      content: 'Alice likes pizza'
    )

    Rails.configuration.stubs(:openai_client).returns(nil)

    messages = Prompt::Assembler.new(@conversation, incoming_message: "pizza").call
    system_content = messages.first[:content]

    assert_includes system_content, 'Long-Term Memory'
    assert_includes system_content, 'Alice likes pizza'
  end

  test 'omits Layer D when incoming_message is nil' do
    MemoryItem.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      conversation: @conversation,
      category: 'fact',
      content: 'Alice likes pizza'
    )

    Rails.configuration.stubs(:openai_client).returns(nil)

    messages = Prompt::Assembler.new(@conversation).call
    system_content = messages.first[:content]

    assert_not_includes system_content, 'Long-Term Memory'
  end

  test 'includes thread catalog with titled conversations' do
    # Create another conversation with a title
    Conversation.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      agent: agents(:steward),
      channel: 'telegram',
      external_thread_key: 'catalog_test',
      title: 'Planning the team offsite'
    )

    messages = Prompt::Assembler.new(@conversation).call
    system_content = messages.first[:content]

    assert_includes system_content, 'Other Conversation Threads'
    assert_includes system_content, 'Planning the team offsite'
  end

  test 'omits thread catalog when no titled conversations exist' do
    messages = Prompt::Assembler.new(@conversation).call
    system_content = messages.first[:content]

    assert_not_includes system_content, 'Other Conversation Threads'
  end
end
