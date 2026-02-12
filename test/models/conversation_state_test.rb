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
    # Advance through the known fixture message (steward_reply)
    known_last = messages(:steward_reply)
    @state.advance_summary!('Summary', known_last.id)

    # Any unsummarized messages should only be ones created after our fixture
    unsummarized = @state.unsummarized_messages
    unsummarized.each do |msg|
      assert msg.id > known_last.id, 'unsummarized message should be newer than summarized_through'
    end
  end
end
