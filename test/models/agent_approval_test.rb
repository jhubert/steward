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

  test "auto_approve? is true when every send_email recipient is a principal" do
    # alice@example.com and bob@example.com are both principals of jennifer
    assert @agent.auto_approve?("send_email", { "to" => "alice@example.com", "cc" => "bob@example.com" })
    assert @agent.auto_approve?("send_email", { "to" => "Alice <ALICE@example.com>" })
    assert @agent.auto_approve?("gmail_new_thread", { "to" => "alice@example.com" })
  end

  test "auto_approve? is false when any recipient is not a principal" do
    refute @agent.auto_approve?("send_email", { "to" => "prospect@acme.com" })
    refute @agent.auto_approve?("send_email", { "to" => "alice@example.com", "cc" => "prospect@acme.com" })
  end

  test "auto_approve? is false for empty recipient list" do
    refute @agent.auto_approve?("send_email", { "to" => "", "cc" => "" })
    refute @agent.auto_approve?("send_email", {})
  end

  test "auto_approve? is false for tools that aren't recipient-aware (e.g. gmail_reply)" do
    refute @agent.auto_approve?("gmail_reply", { "thread_id" => "abc", "body" => "ok" })
    refute @agent.auto_approve?("recall", { "query" => "foo" })
  end

  test "principal_email_set includes external_ids email aliases" do
    alice = users(:alice)
    alice.update!(external_ids: alice.external_ids.merge("emails" => ["alice@example.com", "alice@oldjob.com"]))
    assert_includes @agent.principal_email_set, "alice@oldjob.com"
  end
end
