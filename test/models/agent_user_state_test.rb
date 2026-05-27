require 'test_helper'

class AgentUserStateTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
  end

  test '.for creates a new state for a fresh (user, agent) pair' do
    assert_difference 'AgentUserState.count' do
      AgentUserState.for(user: users(:bob), agent: agents(:steward))
    end
  end

  test '.for is idempotent' do
    first = AgentUserState.for(user: users(:bob), agent: agents(:steward))
    assert_no_difference 'AgentUserState.count' do
      second = AgentUserState.for(user: users(:bob), agent: agents(:steward))
      assert_equal first.id, second.id
    end
  end

  test '#touch_interaction! sets last_interaction_at to message time' do
    state = AgentUserState.for(user: users(:alice), agent: agents(:steward))
    msg = messages(:alice_hello)
    state.touch_interaction!(msg)
    assert_equal msg.created_at, state.reload.last_interaction_at
  end

  test '#touch_interaction! does not rewind for older messages' do
    state = AgentUserState.for(user: users(:alice), agent: agents(:steward))
    later = messages(:alice_hello)
    earlier_time = later.created_at - 1.hour
    state.update!(last_interaction_at: later.created_at)

    older = Message.new(created_at: earlier_time)
    state.touch_interaction!(older)
    assert_equal later.created_at, state.reload.last_interaction_at
  end
end
