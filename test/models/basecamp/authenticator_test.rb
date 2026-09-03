require "test_helper"

class Basecamp::AuthenticatorTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @agent = agents(:jennifer)
    @auth = Basecamp::Authenticator.new(agent: @agent)

    # Every test here would otherwise share one directory (config_home is keyed
    # by agent id), and the suite runs in 4 parallel processes — so one test's
    # teardown deletes files another is still reading. Give each test its own.
    @tmp_home = Rails.root.join("tmp", "basecamp_test", "#{Process.pid}-#{SecureRandom.hex(4)}").to_s
    @auth.stubs(:config_home).returns(@tmp_home)
  end

  teardown do
    FileUtils.rm_rf(@tmp_home)
  end

  test "config_home is scoped per agent so agents cannot read each other's credentials" do
    mine = Basecamp::Authenticator.new(agent: @agent)
    other = Basecamp::Authenticator.new(agent: agents(:steward))
    assert_not_equal mine.config_home, other.config_home
    assert_includes mine.config_home, @agent.id.to_s
  end

  test "configured? is false when no config directory exists" do
    assert_not @auth.configured?
  end

  test "provision! creates the agent's config directory" do
    @auth.provision!
    assert File.directory?(@auth.config_home)
  end

  test "complete_auth rejects a blank callback url" do
    result = @auth.complete_auth("")
    assert_not result.success
    assert_match(/callback URL is required/i, result.error)
  end

  test "complete_auth rejects something that is not a url" do
    result = @auth.complete_auth("i approved it")
    assert_not result.success
    assert_match(/does not look like a callback URL/i, result.error)
  end

  test "complete_auth refuses when no setup is in progress" do
    result = @auth.complete_auth("http://127.0.0.1:8976/callback?code=abc&state=xyz")
    assert_not result.success
    assert_match(/No setup is in progress/i, result.error)
  end

  test "tool_credentials point at the agent's own config home" do
    assert_equal({ "BASECAMP_CONFIG_HOME" => @auth.config_home }, @auth.tool_credentials)
  end

  # The CLI names the bare endpoint in a banner line before printing the real
  # authorization URL. Picking the first match hands the user a link with no
  # client_id or state, which cannot be approved.
  test "extracts the authorizable url, not the bare endpoint from the banner" do
    @auth.provision!
    log = File.join(@auth.config_home, "auth.log")
    File.write(log, <<~LOG)
      Starting Basecamp authentication...
      Authenticating via launchpad (https://launchpad.37signals.com/authorization/new)

      Remote Authentication

        1. Open this URL in a browser on any device:
           https://launchpad.37signals.com/authorization/new?client_id=abc123&redirect_uri=http%3A%2F%2F127.0.0.1%3A8976%2Fcallback&response_type=code&state=xyz789&type=web_server

        2. Sign in to Basecamp when prompted.
    LOG

    url = @auth.send(:extract_auth_url, log)
    assert_includes url, "client_id=abc123"
    assert_includes url, "state=xyz789"
    assert_not_equal "https://launchpad.37signals.com/authorization/new", url
  end

  test "ignores a partially written url so a truncated link is never returned" do
    @auth.provision!
    log = File.join(@auth.config_home, "auth.log")
    # No trailing newline: the bridge is still streaming this line.
    File.write(log, "  1. Open this URL:\n     https://launchpad.37signals.com/authorization/new?client_id=abc&sta")

    assert_nil @auth.send(:extract_auth_url, log)
  end

  test "start_auth reports a clear error when the CLI is missing" do
    @auth.stubs(:resolve_bin).returns(nil)
    result = @auth.start_auth
    assert_not result.success
    assert_match(/basecamp CLI was not found/i, result.error)
  end
end
