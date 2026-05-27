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
      agent: agents(:steward),
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
      agent: agents(:steward),
      conversation: @conversation,
      category: 'fact',
      content: 'Alice likes pizza'
    )

    Rails.configuration.stubs(:openai_client).returns(nil)

    messages = Prompt::Assembler.new(@conversation).call
    system_content = messages.first[:content]

    assert_not_includes system_content, 'Long-Term Memory'
  end

  test 'includes thread catalog with summarized conversations' do
    # Thread catalog renders sibling threads that have a rolling summary.
    # Recent unsummarized activity is covered by the cross-channel timeline;
    # the catalog is for older threads with substantive history.
    sibling = Conversation.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      agent: agents(:steward),
      channel: 'telegram',
      external_thread_key: 'catalog_test',
      title: 'Planning the team offsite'
    )
    sibling.create_state!(
      workspace: workspaces(:default),
      user: users(:alice),
      summary: 'Discussed venue options for the team offsite in Q3.'
    )

    messages = Prompt::Assembler.new(@conversation).call
    system_content = messages.first[:content]

    assert_includes system_content, 'Context From Other Conversations'
    assert_includes system_content, 'Planning the team offsite'
  end

  test 'thread catalog excludes sibling conversations without a summary' do
    Conversation.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      agent: agents(:steward),
      channel: 'telegram',
      external_thread_key: 'catalog_no_summary',
      title: 'Pending compaction'
    )

    messages = Prompt::Assembler.new(@conversation).call
    system_content = messages.first[:content]

    assert_not_includes system_content, 'Context From Other Conversations'
  end

  test 'cross-channel timeline surfaces recent activity from sibling threads' do
    # Create an email thread for the same (user, agent) with a fresh message.
    email_thread = Conversation.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      agent: agents(:steward),
      channel: 'email',
      external_thread_key: 'timeline_email_test'
    )
    cross = email_thread.messages.create!(role: 'user', content: 'Following up on the Q2 deck')
    cross.update_column(:created_at, 30.minutes.ago)

    messages = Prompt::Assembler.new(@conversation).call
    system_content = messages.first[:content]

    assert_includes system_content, 'Recent Activity With This User'
    assert_includes system_content, 'Q2 deck'
    assert_includes system_content, 'email'
  end

  test 'cross-channel timeline excludes the current conversation' do
    # Add a fresh message to the current conversation — it should appear in
    # build_history (the recent-messages window) but NOT in the timeline.
    current_msg = @conversation.messages.create!(role: 'user', content: 'TIMELINE_SELF_EXCLUDE')
    current_msg.update_column(:created_at, 30.minutes.ago)

    messages = Prompt::Assembler.new(@conversation).call
    system_content = messages.first[:content]

    # No timeline section at all when only current-conv messages qualify
    assert_not_includes system_content, 'Recent Activity With This User'
  end

  test 'cross-channel timeline excludes background conversations' do
    bg = Conversation.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      agent: agents(:steward),
      channel: 'background',
      external_thread_key: 'timeline_bg_test'
    )
    msg = bg.messages.create!(role: 'user', content: 'BG_TIMELINE_LEAK')
    msg.update_column(:created_at, 30.minutes.ago)

    messages = Prompt::Assembler.new(@conversation).call
    system_content = messages.first[:content]

    # Background activity has its own briefing section — what we're guarding
    # against is it leaking into the new cross-channel timeline. Either the
    # timeline section is absent entirely, or it doesn't mention the bg message.
    timeline_section = if system_content.include?('## Recent Activity With This User')
      system_content.split('## Recent Activity With This User').last.split(/^## /).first
    else
      ""
    end
    assert_not_includes timeline_section, 'BG_TIMELINE_LEAK'
  end

  test 'cross-channel timeline ignores activity older than 24 hours' do
    email_thread = Conversation.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      agent: agents(:steward),
      channel: 'email',
      external_thread_key: 'timeline_stale_test'
    )
    old = email_thread.messages.create!(role: 'user', content: 'TIMELINE_TOO_OLD')
    old.update_column(:created_at, 2.days.ago)

    messages = Prompt::Assembler.new(@conversation).call
    system_content = messages.first[:content]

    assert_not_includes system_content, 'TIMELINE_TOO_OLD'
  end

  test 'omits thread catalog when no other conversations exist' do
    messages = Prompt::Assembler.new(@conversation).call
    system_content = messages.first[:content]

    assert_not_includes system_content, 'Context From Other Conversations'
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

  test 'build_history includes overlap messages before summarized_through_message_id' do
    # Create messages: some old (well before cutoff), some near the cutoff, some after
    far_old_msgs = (Prompt::Assembler::OVERLAP_MESSAGES + 2).times.map do |i|
      @conversation.messages.create!(
        workspace: workspaces(:default), user: users(:alice),
        role: i.even? ? 'user' : 'assistant',
        content: "Far old message #{i}"
      )
    end

    cutoff_msg = @conversation.messages.create!(
      workspace: workspaces(:default), user: users(:alice),
      role: 'assistant', content: 'Message right at compaction cutoff'
    )
    new_msg = @conversation.messages.create!(
      workspace: workspaces(:default), user: users(:alice),
      role: 'user', content: 'New message after compaction'
    )

    @conversation.state.update!(
      summary: 'Alice greeted Steward.',
      summarized_through_message_id: cutoff_msg.id
    )

    messages = Prompt::Assembler.new(@conversation).call

    # The system message should include the summary
    assert_includes messages.first[:content], 'Alice greeted Steward.'

    history_contents = messages[1..].map { |m| m[:content] }

    # Messages well before the cutoff should be excluded (outside overlap window)
    refute history_contents.any? { |c| c.to_s.include?('Far old message 0') }

    # The cutoff message itself should be included (within overlap window)
    assert history_contents.any? { |c| c.to_s.include?('Message right at compaction cutoff') }

    # Messages after the cutoff should be included
    assert history_contents.any? { |c| c.to_s.include?('New message after compaction') }
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

    assert system_content.include?('EST') || system_content.include?('EDT'),
           'Expected system content to include EST or EDT'
  end

  test 'includes background activity briefing when background conversation has recent activity' do
    agent = @conversation.agent
    user = @conversation.user

    bg_conversation = Conversation.find_or_start(
      user: user,
      agent: agent,
      channel: "background",
      external_thread_key: "background:#{agent.id}:#{user.id}"
    )
    bg_conversation.ensure_state!
    bg_conversation.messages.create!(
      workspace: workspaces(:default), user: user,
      role: 'user', content: 'New email from boss@example.com about Q1 report'
    )
    bg_conversation.messages.create!(
      workspace: workspaces(:default), user: user,
      role: 'assistant', content: 'I found an email about the Q1 report deadline.'
    )

    messages = Prompt::Assembler.new(@conversation).call
    system_content = messages.first[:content]

    assert_includes system_content, 'Background Activity Briefing'
    assert_includes system_content, 'Q1 report'
  end

  test 'omits background activity briefing when no background conversation exists' do
    messages = Prompt::Assembler.new(@conversation).call
    system_content = messages.first[:content]

    assert_not_includes system_content, 'Background Activity Briefing'
  end

  test 'omits background activity briefing when background is stale' do
    agent = @conversation.agent
    user = @conversation.user

    bg_conversation = Conversation.find_or_start(
      user: user,
      agent: agent,
      channel: "background",
      external_thread_key: "background:#{agent.id}:#{user.id}"
    )
    bg_conversation.ensure_state!
    bg_conversation.messages.create!(
      workspace: workspaces(:default), user: user,
      role: 'assistant', content: 'Old background activity',
      created_at: 25.hours.ago
    )

    messages = Prompt::Assembler.new(@conversation).call
    system_content = messages.first[:content]

    assert_not_includes system_content, 'Background Activity Briefing'
  end

  test 'omits background activity briefing for background conversations themselves' do
    bg_conversation = Conversation.find_or_start(
      user: users(:alice),
      agent: agents(:steward),
      channel: "background",
      external_thread_key: "background:self_test"
    )
    bg_conversation.ensure_state!
    bg_conversation.messages.create!(
      workspace: workspaces(:default), user: users(:alice),
      role: 'user', content: 'Background trigger'
    )

    messages = Prompt::Assembler.new(bg_conversation).call
    system_content = messages.first[:content]

    assert_not_includes system_content, 'Background Activity Briefing'
  end
end
