require 'test_helper'

class ConversationStateTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @state = conversation_states(:alice_telegram_state)
  end

  test 'unsummarized_messages returns all when nothing summarized' do
    messages = @state.unsummarized_messages
    assert_equal 2, messages.count
  end

  test 'advance_summary! updates summary and pointer' do
    last_message = messages(:steward_reply)
    @state.advance_summary!('Alice greeted Steward.', last_message.id)

    @state.reload
    assert_equal 'Alice greeted Steward.', @state.summary
    assert_equal last_message.id, @state.summarized_through_message_id
  end

  test 'unsummarized_messages filters after advance' do
    last_msg = @state.conversation.messages.chronological.last
    @state.advance_summary!('Summary', last_msg.id)
    assert_equal 0, @state.unsummarized_messages.count
  end
end
