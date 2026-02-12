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
end
