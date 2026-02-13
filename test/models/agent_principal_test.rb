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

  test 'credentials returns empty hash when credentials_json is blank' do
    ap = agent_principals(:jennifer_alice)
    assert_equal({}, ap.credentials)
  end

  test 'credentials round-trips through setter and getter' do
    ap = agent_principals(:jennifer_alice)
    ap.credentials = { "gog_keyring_password" => "secret123" }
    ap.save!
    ap.reload
    assert_equal({ "gog_keyring_password" => "secret123" }, ap.credentials)
  end

  test 'credentials setter clears with nil' do
    ap = agent_principals(:jennifer_alice)
    ap.credentials = { "key" => "val" }
    ap.save!
    ap.credentials = nil
    ap.save!
    ap.reload
    assert_equal({}, ap.credentials)
  end

  test 'credentials_json is encrypted' do
    ap = agent_principals(:jennifer_alice)
    ap.credentials = { "gog_keyring_password" => "secret123" }
    ap.save!

    raw = ActiveRecord::Base.connection.select_value(
      "SELECT credentials_json FROM agent_principals WHERE id = #{ap.id}"
    )
    assert_not_nil raw
    assert_not_equal ap.credentials.to_json, raw
  end
end
