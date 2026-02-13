require "test_helper"

class Gog::SetupTokenTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @user = users(:alice)
    @agent = agents(:jennifer)
    @workspace = workspaces(:default)
  end

  test "generate and verify roundtrip" do
    token = Gog::SetupToken.generate(user: @user, agent: @agent, workspace: @workspace)
    data = Gog::SetupToken.verify(token)

    assert_not_nil data
    assert_equal @user.id, data[:user_id]
    assert_equal @agent.id, data[:agent_id]
    assert_equal @workspace.id, data[:workspace_id]
  end

  test "expired token returns nil" do
    token = travel_to(2.hours.ago) do
      Gog::SetupToken.generate(user: @user, agent: @agent, workspace: @workspace)
    end

    assert_nil Gog::SetupToken.verify(token)
  end

  test "tampered token returns nil" do
    token = Gog::SetupToken.generate(user: @user, agent: @agent, workspace: @workspace)
    tampered = token + "x"

    assert_nil Gog::SetupToken.verify(tampered)
  end

  test "token is valid within expiry window" do
    token = travel_to(30.minutes.ago) do
      Gog::SetupToken.generate(user: @user, agent: @agent, workspace: @workspace)
    end

    data = Gog::SetupToken.verify(token)
    assert_not_nil data
    assert_equal @user.id, data[:user_id]
  end
end
