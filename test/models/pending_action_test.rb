require 'test_helper'

class PendingActionTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @agent = agents(:jennifer)
    @conversation = conversations(:alice_jennifer)
    @approver = users(:alice)
  end

  def build_pending(**overrides)
    PendingAction.create!({
      workspace: workspaces(:default),
      agent: @agent,
      conversation: @conversation,
      approver_user: @approver,
      tool_name: "send_email",
      tool_input: { "to" => "x@example.com", "subject" => "Hi", "body" => "Hello" }
    }.merge(overrides))
  end

  test "creating a pending action defaults to pending status and a 24h expiry" do
    travel_to Time.current do
      pa = build_pending
      assert pa.pending?
      assert_in_delta 24.hours.from_now.to_i, pa.expires_at.to_i, 5
    end
  end

  test "callback_data round-trips through parse_callback" do
    pa = build_pending
    parsed = PendingAction.parse_callback(pa.callback_data("approve"))
    assert_equal pa.id, parsed[:id]
    assert_equal "approve", parsed[:decision]
  end

  test "parse_callback returns nil for garbage" do
    assert_nil PendingAction.parse_callback(nil)
    assert_nil PendingAction.parse_callback("hello world")
    assert_nil PendingAction.parse_callback("pa:abc:approve")
  end

  test "expired_now? is true only for past-expiry pending records" do
    pa = build_pending(expires_at: 1.hour.ago)
    assert pa.expired_now?

    pa.update!(status: "approved")
    refute pa.expired_now?, "resolved actions are never 'expired_now'"
  end

  test "status inclusion validation rejects garbage" do
    pa = build_pending
    pa.status = "weird"
    refute pa.valid?
    assert_includes pa.errors[:status].first, "is not included"
  end
end
