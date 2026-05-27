require 'test_helper'

class Memory::EpisodeBuilderTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @conv = conversations(:alice_jennifer)
  end

  test 'persists an Episode with title and summary' do
    msgs = @conv.messages.chronological.to_a

    Memory::EpisodeBuilder.any_instance.stubs(:generate_title_and_summary)
                          .returns(["Schedule sync", "Alice asked Jennifer to plan the day."])
    Memory::EpisodeBuilder.any_instance.stubs(:generate_embedding).returns(nil)

    ep = nil
    assert_difference 'Episode.count' do
      ep = Memory::EpisodeBuilder.new(
        conversation: @conv,
        first_message_id: msgs.first.id,
        last_message_id: msgs.last.id
      ).call
    end

    assert_equal 'Schedule sync', ep.title
    assert_match(/Alice/, ep.summary)
    assert_equal @conv.channel, ep.channel
    assert_equal msgs.first.id, ep.first_message_id
    assert_equal msgs.last.id, ep.last_message_id
  end

  test 'returns nil when summary comes back blank' do
    msgs = @conv.messages.chronological.to_a

    Memory::EpisodeBuilder.any_instance.stubs(:generate_title_and_summary).returns(["x", ""])
    Memory::EpisodeBuilder.any_instance.stubs(:generate_embedding).returns(nil)

    assert_no_difference 'Episode.count' do
      result = Memory::EpisodeBuilder.new(
        conversation: @conv,
        first_message_id: msgs.first.id,
        last_message_id: msgs.last.id
      ).call
      assert_nil result
    end
  end

  test 'returns nil when message range is empty' do
    assert_no_difference 'Episode.count' do
      result = Memory::EpisodeBuilder.new(
        conversation: @conv,
        first_message_id: 0,
        last_message_id: 0
      ).call
      assert_nil result
    end
  end
end
