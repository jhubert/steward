require "test_helper"

class Tools::EmailGate::AllowlistTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @agent = agents(:jennifer)
  end

  test "allows principal email addresses" do
    # jennifer_alice fixture makes alice a principal
    allowlist = Tools::EmailGate::Allowlist.new(@agent)
    result = allowlist.call([users(:alice).email])
    assert result.ok?
    assert_empty result.blocked
  end

  test "blocks strangers not in principal list or inbound history" do
    allowlist = Tools::EmailGate::Allowlist.new(@agent)
    result = allowlist.call(["stranger@example.com"])
    refute result.ok?
    assert_includes result.blocked, "stranger@example.com"
  end

  test "allows addresses in explicit email_allowlist setting" do
    @agent.settings["email_allowlist"] = ["vendor@external.com"]
    @agent.save!

    allowlist = Tools::EmailGate::Allowlist.new(@agent)
    result = allowlist.call(["vendor@external.com"])
    assert result.ok?
  end

  test "allows addresses from inbound email history" do
    # Create an email conversation with a sender in metadata
    conv = Conversation.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      agent: @agent,
      channel: "email",
      external_thread_key: "test-thread-123",
      metadata: {
        "email_participants" => [{ "email" => "past-sender@known.com", "name" => "Past Sender" }]
      }
    )

    allowlist = Tools::EmailGate::Allowlist.new(@agent)
    result = allowlist.call(["past-sender@known.com"])
    assert result.ok?, "expected pass for past inbound sender, got blocked: #{result.blocked}"
  end

  test "partitions mixed allowed/blocked recipients correctly" do
    @agent.settings["email_allowlist"] = ["ok@allowed.com"]
    @agent.save!

    allowlist = Tools::EmailGate::Allowlist.new(@agent)
    result = allowlist.call(["ok@allowed.com, bad@unknown.com"])
    refute result.ok?
    assert_equal ["bad@unknown.com"], result.blocked
    assert_equal ["ok@allowed.com"], result.allowed
  end

  test "parses recipient strings with Name <email> format" do
    @agent.settings["email_allowlist"] = ["alice@example.com"]
    @agent.save!

    allowlist = Tools::EmailGate::Allowlist.new(@agent)
    result = allowlist.call(["Alice Smith <alice@example.com>"])
    assert result.ok?
  end

  test "case-insensitive matching" do
    @agent.settings["email_allowlist"] = ["Vendor@Example.COM"]
    @agent.save!

    allowlist = Tools::EmailGate::Allowlist.new(@agent)
    result = allowlist.call(["vendor@example.com"])
    assert result.ok?
  end

  test "empty recipient list is allowed" do
    allowlist = Tools::EmailGate::Allowlist.new(@agent)
    result = allowlist.call([])
    assert result.ok?
  end
end
