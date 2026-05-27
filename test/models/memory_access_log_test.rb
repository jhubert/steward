require 'test_helper'

class MemoryAccessLogTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
  end

  test '.record persists a log entry' do
    assert_difference 'MemoryAccessLog.count' do
      MemoryAccessLog.record(
        workspace: workspaces(:default),
        agent: agents(:jennifer),
        viewing_user: users(:alice),
        subject_user: users(:bob),
        conversation: conversations(:alice_jennifer),
        context: 'principal_context'
      )
    end
  end

  test '.record accepts subject_user_id directly' do
    assert_difference 'MemoryAccessLog.count' do
      MemoryAccessLog.record(
        workspace: workspaces(:default),
        agent: agents(:jennifer),
        viewing_user: users(:alice),
        subject_user_id: users(:bob).id,
        context: 'recall_tool'
      )
    end
  end

  test '.record swallows errors so it never breaks callers' do
    # Invalid workspace — would raise on create!. .record should rescue.
    result = nil
    assert_nothing_raised do
      result = MemoryAccessLog.record(
        workspace: nil,
        agent: agents(:jennifer),
        viewing_user: users(:alice),
        subject_user: users(:bob),
        context: 'principal_context'
      )
    end
    assert_nil result
  end
end
