require 'test_helper'

class MessageTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
  end

  test 'validates role inclusion' do
    message = Message.new(
      conversation: conversations(:alice_telegram),
      user: users(:alice),
      role: 'invalid',
      content: 'test'
    )
    assert_not message.valid?
    assert_includes message.errors[:role], 'is not included in the list'
  end

  test 'chronological scope orders by created_at' do
    messages = conversations(:alice_telegram).messages.chronological
    assert_equal messages, messages.sort_by(&:created_at)
  end

  test 'unsummarized_since returns all messages when no id given' do
    messages = conversations(:alice_telegram).messages.unsummarized_since(nil)
    assert_equal 2, messages.count
  end

  test 'unsummarized_since filters by id' do
    first = messages(:alice_hello)
    unsummarized = conversations(:alice_telegram).messages.unsummarized_since(first.id)
    assert_not_includes unsummarized, first
  end
end
