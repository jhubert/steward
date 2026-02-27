require "test_helper"

class InviteTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
  end

  test "valid invite" do
    invite = Invite.new(
      workspace: workspaces(:default),
      invited_by: users(:alice),
      email: "new@example.com",
      status: "pending"
    )
    assert invite.valid?
  end

  test "requires email" do
    invite = Invite.new(
      workspace: workspaces(:default),
      invited_by: users(:alice),
      status: "pending"
    )
    assert_not invite.valid?
    assert invite.errors[:email].any?
  end

  test "enforces unique email per workspace" do
    invite = Invite.new(
      workspace: workspaces(:default),
      invited_by: users(:alice),
      email: "bob@example.com",
      status: "pending"
    )
    assert_not invite.valid?
    assert invite.errors[:email].any?
  end

  test "validates status inclusion" do
    invite = invites(:pending_invite)
    invite.status = "invalid"
    assert_not invite.valid?
    assert invite.errors[:status].any?
  end

  test "allowed? returns true for pending invite" do
    assert Invite.allowed?("bob@example.com")
  end

  test "allowed? returns false for revoked invite" do
    assert_not Invite.allowed?("revoked@example.com")
  end

  test "allowed? returns false for unknown email" do
    assert_not Invite.allowed?("unknown@example.com")
  end

  test "allowed? is case-insensitive" do
    assert Invite.allowed?("BOB@EXAMPLE.COM")
  end

  test "accept! transitions to accepted" do
    invite = invites(:pending_invite)
    invite.accept!
    assert invite.accepted?
    assert_equal "accepted", invite.reload.status
  end

  test "revoke! transitions to revoked" do
    invite = invites(:pending_invite)
    invite.revoke!
    assert invite.revoked?
    assert_equal "revoked", invite.reload.status
  end

  test "pending? returns true for pending invite" do
    assert invites(:pending_invite).pending?
  end

  test "accepted? returns true after accept!" do
    invite = invites(:pending_invite)
    invite.accept!
    assert invite.accepted?
  end

  test "active scope includes pending and accepted" do
    invites(:pending_invite).accept!
    active_emails = Invite.active.pluck(:email)
    assert_includes active_emails, "bob@example.com"
    assert_not_includes active_emails, "revoked@example.com"
  end

  test "allowed? returns true for accepted invite" do
    invites(:pending_invite).accept!
    assert Invite.allowed?("bob@example.com")
  end
end
