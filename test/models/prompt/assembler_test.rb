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

  test 'includes platform charter before agent core' do
    messages = Prompt::Assembler.new(@conversation).call
    system_content = messages.first[:content]

    assert_includes system_content, 'Agent Charter'
    assert_includes system_content, 'Be resourceful'
    # Charter should appear before the agent's own system prompt
    charter_pos = system_content.index('Agent Charter')
    agent_pos = system_content.index('Steward')
    assert charter_pos < agent_pos, 'Charter should appear before agent core'
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

  test 'includes date context with current date and calendar reference' do
    messages = Prompt::Assembler.new(@conversation).call
    system_content = messages.first[:content]

    today = Time.current.in_time_zone("Pacific Time (US & Canada)").to_date

    assert_includes system_content, 'Current Date & Time'
    assert_includes system_content, today.strftime('%A, %B %-d, %Y')
    assert_includes system_content, 'Calendar Reference'
    # Verify it contains day-of-week abbreviations for lookup
    assert_includes system_content, 'Mon'
    assert_includes system_content, 'Fri'
  end

  test 'includes capabilities context with builtin tools' do
    messages = Prompt::Assembler.new(@conversation).call
    system_content = messages.first[:content]

    assert_includes system_content, 'Your Capabilities'
    assert_includes system_content, 'download_file'
    assert_includes system_content, 'schedule_task'
  end

  test 'includes agent-specific tools in capabilities context' do
    conversation = conversations(:alice_jennifer)
    conversation.ensure_state!

    messages = Prompt::Assembler.new(conversation).call
    system_content = messages.first[:content]

    assert_includes system_content, 'Your Capabilities'
    assert_includes system_content, 'github'
    assert_includes system_content, 'find_availability'
  end

  test 'build_history excludes messages before summarized_through_message_id' do
    # Create messages with known ordering (IDs are sequential for created records)
    old_msg = @conversation.messages.create!(
      workspace: workspaces(:default), user: users(:alice),
      role: 'user', content: 'Old message before compaction'
    )
    new_msg = @conversation.messages.create!(
      workspace: workspaces(:default), user: users(:alice),
      role: 'assistant', content: 'New message after compaction'
    )

    # Mark through old_msg as summarized
    @conversation.state.update!(
      summary: 'Alice greeted Steward.',
      summarized_through_message_id: old_msg.id
    )

    messages = Prompt::Assembler.new(@conversation).call

    # The system message should include the summary
    assert_includes messages.first[:content], 'Alice greeted Steward.'

    # History should NOT include the old message's content
    history_contents = messages[1..].map { |m| m[:content] }
    refute_includes history_contents, 'Old message before compaction'

    # History SHOULD include messages after the pointer
    assert_includes history_contents, 'New message after compaction'
  end

  test 'includes background context for background conversations' do
    bg_conversation = Conversation.find_or_start(
      user: users(:alice),
      agent: agents(:steward),
      channel: "background",
      external_thread_key: "background:test"
    )
    bg_conversation.ensure_state!

    messages = Prompt::Assembler.new(bg_conversation).call
    system_content = messages.first[:content]

    assert_includes system_content, 'Background Processing Mode'
    assert_includes system_content, 'send_message'
    assert_includes system_content, 'NOT delivered to anyone'
  end

  test 'omits background context for normal conversations' do
    messages = Prompt::Assembler.new(@conversation).call
    system_content = messages.first[:content]

    assert_not_includes system_content, 'Background Processing Mode'
  end

  test 'includes send_message capability hint for background conversations' do
    bg_conversation = Conversation.find_or_start(
      user: users(:alice),
      agent: agents(:steward),
      channel: "background",
      external_thread_key: "background:cap_test"
    )
    bg_conversation.ensure_state!

    messages = Prompt::Assembler.new(bg_conversation).call
    system_content = messages.first[:content]

    assert_includes system_content, '**send_message**'
  end

  test 'omits send_message capability hint for normal conversations' do
    messages = Prompt::Assembler.new(@conversation).call
    system_content = messages.first[:content]

    assert_not_includes system_content, '**send_message**'
  end

  test 'date context uses agent timezone setting when configured' do
    agent = @conversation.agent
    agent.update!(settings: agent.settings.merge("timezone" => "Eastern Time (US & Canada)"))

    messages = Prompt::Assembler.new(@conversation).call
    system_content = messages.first[:content]

    assert_includes system_content, 'EST'
  end
end
