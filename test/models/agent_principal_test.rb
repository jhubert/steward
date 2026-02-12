require 'test_helper'

class AgentPrincipalTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
  end

  test 'belongs to agent and user' do
    ap = agent_principals(:jennifer_alice)
    assert_equal agents(:jennifer), ap.agent
    assert_equal users(:alice), ap.user
  end

  test 'enforces uniqueness of agent + user within workspace' do
    duplicate = AgentPrincipal.new(
      workspace: workspaces(:default),
      agent: agents(:jennifer),
      user: users(:alice),
      role: 'Duplicate'
    )
    assert_not duplicate.valid?
  end

  test 'label returns display_name when present' do
    ap = agent_principals(:jennifer_alice)
    assert_equal 'Alice', ap.label
  end

  test 'label falls back to user name when display_name is blank' do
    ap = agent_principals(:jennifer_alice)
    ap.display_name = nil
    assert_equal 'Alice', ap.label
  end

  test 'roster_entry includes role when present' do
    ap = agent_principals(:jennifer_alice)
    assert_equal 'Alice (CEO)', ap.roster_entry
  end

  test 'roster_entry omits role when blank' do
    ap = agent_principals(:jennifer_alice)
    ap.role = nil
    assert_equal 'Alice', ap.roster_entry
  end
end
