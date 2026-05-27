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

  test 'supersede! marks the old item and links it to the new one' do
    old = MemoryItem.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      content: "Alice prefers morning meetings",
      category: 'preference'
    )
    new_item = MemoryItem.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      content: "Alice prefers afternoon meetings since school pickup changed",
      category: 'preference'
    )

    old.supersede!(by: new_item)

    assert_not_nil old.reload.superseded_at
    assert_equal old.id, new_item.reload.supersedes_id
  end

  test 'current scope excludes superseded items' do
    old = MemoryItem.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      content: "OUTDATED preference",
      category: 'preference'
    )
    new_item = MemoryItem.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      content: "Current preference",
      category: 'preference'
    )
    old.supersede!(by: new_item)

    current = MemoryItem.current.where(user: users(:alice))
    assert_includes current, new_item
    assert_not_includes current, old
  end
end
