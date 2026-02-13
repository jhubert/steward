require "test_helper"
require "open3"

class SetupControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:alice)
    @agent = agents(:jennifer)
    @workspace = workspaces(:default)
    @principal = agent_principals(:jennifer_alice)
    @token = Gog::SetupToken.generate(user: @user, agent: @agent, workspace: @workspace)
  end

  test "show renders email form with valid token" do
    get google_setup_path(token: @token)
    assert_response :success
    assert_select "input[type=email]"
  end

  test "show returns 410 for expired token" do
    expired_token = travel_to(2.hours.ago) do
      Gog::SetupToken.generate(user: @user, agent: @agent, workspace: @workspace)
    end

    get google_setup_path(token: expired_token)
    assert_response :gone
  end

  test "show returns 410 for invalid token" do
    get google_setup_path(token: "garbage")
    assert_response :gone
  end

  test "start with blank email re-renders show with error" do
    post google_setup_start_path(token: @token), params: { email: "" }
    assert_response :success
    assert_select ".error"
  end

  test "start with valid email calls authenticator and renders auth_url" do
    auth_result = Gog::Authenticator::Result.new(
      success: true,
      output: "https://accounts.google.com/o/oauth2/v2/auth?client_id=123",
      error: nil
    )
    Gog::Authenticator.any_instance.stubs(:start_auth).returns(auth_result)

    post google_setup_start_path(token: @token), params: { email: "alice@gmail.com" }
    assert_response :success
    assert_select "a.auth-link[href*='accounts.google.com']"
  end

  test "start with auth failure re-renders show with error" do
    auth_result = Gog::Authenticator::Result.new(
      success: false,
      output: "",
      error: "credentials invalid"
    )
    Gog::Authenticator.any_instance.stubs(:start_auth).returns(auth_result)

    post google_setup_start_path(token: @token), params: { email: "alice@gmail.com" }
    assert_response :success
    assert_select ".error"
  end

  test "complete with blank auth_url re-renders auth_url with error" do
    post google_setup_complete_path(token: @token), params: {
      email: "alice@gmail.com",
      auth_url: "",
      original_auth_url: "https://accounts.google.com/..."
    }
    assert_response :success
    assert_select ".error"
  end

  test "complete with valid auth_url renders success" do
    auth_result = Gog::Authenticator::Result.new(success: true, output: "Token saved", error: nil)
    Gog::Authenticator.any_instance.stubs(:complete_auth).returns(auth_result)

    post google_setup_complete_path(token: @token), params: {
      email: "alice@gmail.com",
      auth_url: "http://localhost:1/?code=abc&state=xyz"
    }
    assert_response :success
    assert_select "h1", /Connected/
  end

  test "complete with auth failure re-renders auth_url with error" do
    auth_result = Gog::Authenticator::Result.new(success: false, output: "", error: "invalid code")
    Gog::Authenticator.any_instance.stubs(:complete_auth).returns(auth_result)

    post google_setup_complete_path(token: @token), params: {
      email: "alice@gmail.com",
      auth_url: "http://localhost:1/?code=bad",
      original_auth_url: "https://accounts.google.com/..."
    }
    assert_response :success
    assert_select ".error"
  end
end
