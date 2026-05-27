require 'test_helper'

class ConversationTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
  end

  test 'find_or_start creates new conversation' do
    assert_difference 'Conversation.count' do
      Conversation.find_or_start(
        user: users(:bob),
        agent: agents(:steward),
        channel: 'telegram',
        external_thread_key: '222222'
      )
    end
  end

  test 'find_or_start finds existing conversation' do
    assert_no_difference 'Conversation.count' do
      conv = Conversation.find_or_start(
        user: users(:alice),
        agent: agents(:steward),
        channel: 'telegram',
        external_thread_key: '111111'
      )
      assert_equal conversations(:alice_telegram), conv
    end
  end

  test 'ensure_state! creates state if missing' do
    conv = Conversation.find_or_start(
      user: users(:bob),
      agent: agents(:steward),
      channel: 'telegram',
      external_thread_key: '222222'
    )

    assert_nil conv.state
    state = conv.ensure_state!
    assert_instance_of ConversationState, state
    assert_equal conv, state.conversation
  end

  test 'needs_compaction? returns false when under threshold' do
    conv = conversations(:alice_telegram)
    assert_not conv.needs_compaction?
  end

  test 'needs_extraction? returns false when under threshold' do
    conv = conversations(:alice_telegram)
    assert_not conv.needs_extraction?
  end

  test 'needs_extraction? returns true when at threshold' do
    conv = conversations(:alice_telegram)
    # Add messages to reach extraction threshold (already has 2 from fixtures)
    (Conversation::EXTRACTION_THRESHOLD - 2).times do |i|
      conv.messages.create!(
        workspace: conv.workspace,
        user: conv.user,
        role: i.even? ? 'user' : 'assistant',
        content: "Message #{i}"
      )
    end

    assert conv.needs_extraction?
  end

  # --- Idle triggers (Phase 1) ---

  test 'stale_for_compaction? false when no messages' do
    conv = Conversation.create!(
      workspace: workspaces(:default),
      user: users(:bob),
      agent: agents(:steward),
      channel: 'telegram',
      external_thread_key: 'idle_test_empty'
    )
    assert_not conv.stale_for_compaction?
  end

  test 'stale_for_compaction? false when latest message is fresh' do
    conv = conversations(:alice_telegram)
    assert_not conv.stale_for_compaction?
  end

  test 'stale_for_compaction? true when latest unsummarized message is older than IDLE_HOURS' do
    conv = conversations(:alice_telegram)
    conv.messages.each { |m| m.update_column(:created_at, (Conversation::IDLE_HOURS + 1).hours.ago) }
    assert conv.stale_for_compaction?
  end

  test 'stale_for_compaction? false once all messages are already summarized' do
    conv = conversations(:alice_telegram)
    conv.messages.each { |m| m.update_column(:created_at, 1.week.ago) }
    last_id = conv.messages.order(:id).last.id
    conv.ensure_state!.update!(summarized_through_message_id: last_id, summary: 'done')
    assert_not conv.stale_for_compaction?
  end

  test 'stale_for_extraction? mirrors compaction logic against extraction pointer' do
    conv = conversations(:alice_telegram)
    conv.messages.each { |m| m.update_column(:created_at, (Conversation::IDLE_HOURS + 1).hours.ago) }
    assert conv.stale_for_extraction?

    last_id = conv.messages.order(:id).last.id
    conv.ensure_state!.update!(extracted_through_message_id: last_id)
    assert_not conv.stale_for_extraction?
  end

  test 'needs_compaction? returns true via idle trigger even below count threshold' do
    conv = conversations(:alice_telegram)
    conv.messages.each { |m| m.update_column(:created_at, (Conversation::IDLE_HOURS + 1).hours.ago) }
    assert conv.needs_compaction?
  end

  # --- find_by_email_thread ---

  test 'find_by_email_thread finds email conversation by thread key regardless of user' do
    conv = conversations(:alice_jennifer_email)
    found = Conversation.find_by_email_thread(
      workspace: workspaces(:default),
      agent: agents(:jennifer),
      thread_key: conv.external_thread_key
    )
    assert_equal conv, found
  end

  test 'find_by_email_thread returns nil for non-existent thread key' do
    found = Conversation.find_by_email_thread(
      workspace: workspaces(:default),
      agent: agents(:jennifer),
      thread_key: "<nonexistent@example.com>"
    )
    assert_nil found
  end

  test 'find_by_email_thread does not match non-email conversations' do
    found = Conversation.find_by_email_thread(
      workspace: workspaces(:default),
      agent: agents(:steward),
      thread_key: "111111"
    )
    assert_nil found
  end

  test 'find_by_email_thread fuzzy-matches when Message-ID domain differs' do
    # Simulate outbound email stored with @withstuart.com domain
    conv = Conversation.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      agent: agents(:jennifer),
      channel: "email",
      external_thread_key: "<abc123-def456@withstuart.com>"
    )

    # Incoming reply references @mtasv.net (Postmark's actual MTA domain)
    found = Conversation.find_by_email_thread(
      workspace: workspaces(:default),
      agent: agents(:jennifer),
      thread_key: "<abc123-def456@mtasv.net>"
    )
    assert_equal conv, found
  end

  # --- merge_email_participants! ---

  test 'merge_email_participants! adds new participants' do
    conv = conversations(:alice_jennifer_email)
    conv.update!(metadata: (conv.metadata || {}).merge("email_participants" => [
      { "email" => "alice@example.com", "name" => "Alice" }
    ]))

    conv.merge_email_participants!([
      { "email" => "bob@example.com", "name" => "Bob" },
      { "email" => "alice@example.com", "name" => "Alice Dup" }
    ])

    conv.reload
    participants = conv.metadata["email_participants"]
    assert_equal 2, participants.size
    assert_equal ["alice@example.com", "bob@example.com"], participants.map { |p| p["email"] }.sort
  end

  test 'merge_email_participants! works with empty existing participants' do
    conv = conversations(:alice_jennifer_email)
    conv.update!(metadata: conv.metadata.except("email_participants"))

    conv.merge_email_participants!([
      { "email" => "new@example.com", "name" => "New Person" }
    ])

    conv.reload
    assert_equal 1, conv.metadata["email_participants"].size
  end

  test 'needs_extraction? respects extracted_through pointer' do
    conv = conversations(:alice_telegram)
    state = conv.ensure_state!

    # Add messages to reach threshold
    (Conversation::EXTRACTION_THRESHOLD - 2).times do |i|
      conv.messages.create!(
        workspace: conv.workspace,
        user: conv.user,
        role: i.even? ? 'user' : 'assistant',
        content: "Message #{i}"
      )
    end

    assert conv.needs_extraction?

    # Advance pointer past all messages
    state.advance_extraction!(conv.messages.last.id)
    assert_not conv.needs_extraction?
  end
end
