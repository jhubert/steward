require 'test_helper'

class AgentApprovalTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @agent = agents(:jennifer)
  end

  test "approval_required_tools defaults to empty" do
    assert_equal [], @agent.approval_required_tools
    refute @agent.approval_required?("send_email")
  end

  test "approval_required? matches configured tools" do
    @agent.update!(settings: @agent.settings.merge("approval_required_tools" => ["send_email", "gmail_reply"]))
    assert @agent.approval_required?("send_email")
    assert @agent.approval_required?(:gmail_reply)
    refute @agent.approval_required?("recall")
  end

  test "approver_user falls back to first principal" do
    # Alice is jennifer's first principal in fixture order
    assert_equal users(:alice), @agent.approver_user
  end

  test "approver_user honors explicit approval_approver_user_id" do
    bob = users(:bob)
    @agent.update!(settings: @agent.settings.merge("approval_approver_user_id" => bob.id))
    assert_equal bob, @agent.approver_user
  end

  test "approval_conversation_for finds the most recent telegram thread" do
    conv = @agent.approval_conversation_for(users(:alice))
    assert_equal conversations(:alice_jennifer), conv
  end

  test "approval_conversation_for returns nil when no telegram conversation exists" do
    markus = agents(:markus)
    bob = users(:bob)
    # bob has no telegram conversation with markus in fixtures
    assert_nil markus.approval_conversation_for(bob)
  end
end
