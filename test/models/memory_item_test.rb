require 'test_helper'

class MemoryItemTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
  end

  test 'requires content' do
    item = MemoryItem.new(workspace: workspaces(:default), user: users(:alice))
    assert_not item.valid?
    assert_includes item.errors[:content], "can't be blank"
  end

  test 'conversation is optional' do
    item = MemoryItem.new(
      workspace: workspaces(:default),
      user: users(:alice),
      content: 'A cross-thread fact',
      category: 'fact'
    )
    assert item.valid?
  end
end
