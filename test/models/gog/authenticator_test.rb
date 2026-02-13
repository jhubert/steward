require "test_helper"
require "open3"

class Gog::AuthenticatorTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @principal = agent_principals(:jennifer_alice)
    @authenticator = Gog::Authenticator.new(agent_principal: @principal)
  end

  test "configured? returns false when no keyring password" do
    assert_not @authenticator.configured?
  end

  test "configured? returns true when keyring password exists" do
    @principal.credentials = { "gog_keyring_password" => "secret" }
    @principal.save!

    assert @authenticator.configured?
  end

  test "provision! creates user data dir and stores keyring password" do
    client_secret = Gog::Authenticator::CLIENT_SECRET_PATH

    FileUtils.stubs(:mkdir_p)
    FileUtils.stubs(:cp)
    File.stubs(:exist?).returns(false)

    @authenticator.provision!

    @principal.reload
    assert @principal.credentials.key?("gog_keyring_password")
    assert_equal 64, @principal.credentials["gog_keyring_password"].length
  end

  test "provision! is idempotent — does not overwrite existing password" do
    @principal.credentials = { "gog_keyring_password" => "original_password" }
    @principal.save!

    FileUtils.stubs(:mkdir_p)
    FileUtils.stubs(:cp)
    File.stubs(:exist?).returns(true)

    @authenticator.provision!

    @principal.reload
    assert_equal "original_password", @principal.credentials["gog_keyring_password"]
  end

  test "start_auth returns auth URL on success" do
    @principal.credentials = { "gog_keyring_password" => "pw" }
    @principal.save!

    FileUtils.stubs(:mkdir_p)
    FileUtils.stubs(:cp)
    File.stubs(:exist?).returns(true)

    auth_output = "Visit this URL to authorize: https://accounts.google.com/o/oauth2/v2/auth?client_id=123&redirect_uri=http://localhost:1/&scope=openid\n"
    status = stub(exitstatus: 0)
    Open3.stubs(:capture3).returns([auth_output, "", status])

    result = @authenticator.start_auth("alice@gmail.com")

    assert result.success
    assert_match %r{https://accounts\.google\.com}, result.output
  end

  test "start_auth returns error on failure" do
    @principal.credentials = { "gog_keyring_password" => "pw" }
    @principal.save!

    FileUtils.stubs(:mkdir_p)
    FileUtils.stubs(:cp)
    File.stubs(:exist?).returns(true)

    status = stub(exitstatus: 1)
    Open3.stubs(:capture3).returns(["", "invalid credentials", status])

    result = @authenticator.start_auth("bad@gmail.com")

    assert_not result.success
    assert_equal "invalid credentials", result.error
  end

  test "complete_auth returns success on exit 0" do
    @principal.credentials = { "gog_keyring_password" => "pw" }
    @principal.save!

    status = stub(exitstatus: 0)
    Open3.stubs(:capture3).returns(["Token saved", "", status])

    result = @authenticator.complete_auth("alice@gmail.com", "http://localhost:1/?code=abc&state=xyz")

    assert result.success
    assert_equal "Token saved", result.output
  end

  test "complete_auth returns error on failure" do
    @principal.credentials = { "gog_keyring_password" => "pw" }
    @principal.save!

    status = stub(exitstatus: 1)
    Open3.stubs(:capture3).returns(["", "invalid auth code", status])

    result = @authenticator.complete_auth("alice@gmail.com", "http://localhost:1/?code=bad")

    assert_not result.success
    assert_equal "invalid auth code", result.error
  end
end
