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

  test "auto_approve? is false for unrelated tools" do
    refute @agent.auto_approve?("recall", { "query" => "foo" })
  end

  test "auto_approve? for gmail_reply when every thread participant is a principal" do
    # Build a GOG-keyed email conversation whose participants are all principals
    @agent.update!(settings: @agent.settings.merge("gog_email" => "jennifer@boardwise.co"))
    conv = Conversation.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      agent: @agent,
      channel: "email",
      external_thread_key: "gmail:THREAD_INTERNAL"
    )
    conv.update!(metadata: {
      "email_participants" => [
        { "email" => "alice@example.com", "name" => "Alice" },
        { "email" => "bob@example.com",   "name" => "Bob" },
        { "email" => "jennifer@boardwise.co", "name" => "Jennifer" } # self — filtered out
      ]
    })

    assert @agent.auto_approve?("gmail_reply", { "thread_id" => "THREAD_INTERNAL", "body" => "ok" })
  end

  test "auto_approve? for gmail_reply is false when any participant is external" do
    conv = Conversation.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      agent: @agent,
      channel: "email",
      external_thread_key: "gmail:THREAD_MIXED"
    )
    conv.update!(metadata: {
      "email_participants" => [
        { "email" => "alice@example.com", "name" => "Alice" },
        { "email" => "prospect@acme.com", "name" => "Prospect" }
      ]
    })

    refute @agent.auto_approve?("gmail_reply", { "thread_id" => "THREAD_MIXED", "body" => "ok" })
  end

  test "auto_approve? for gmail_reply is false when we can't find the thread (safe default)" do
    refute @agent.auto_approve?("gmail_reply", { "thread_id" => "UNKNOWN", "body" => "ok" })
  end

  test "auto_approve? for gmail_reply is false when participants are missing (safe default)" do
    Conversation.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      agent: @agent,
      channel: "email",
      external_thread_key: "gmail:THREAD_NO_PARTICIPANTS"
    )
    refute @agent.auto_approve?("gmail_reply", { "thread_id" => "THREAD_NO_PARTICIPANTS", "body" => "ok" })
  end

  test "principal_email_set includes external_ids email aliases" do
    alice = users(:alice)
    alice.update!(external_ids: alice.external_ids.merge("emails" => ["alice@example.com", "alice@oldjob.com"]))
    assert_includes @agent.principal_email_set, "alice@oldjob.com"
  end
end
