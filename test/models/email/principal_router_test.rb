require "test_helper"

class Email::PrincipalRouterTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @agent = agents(:jennifer)
    @router = Email::PrincipalRouter.new(agent: @agent)
  end

  test "returns nil when no principals have email contacts" do
    # Remove email contacts from all principals
    @agent.agent_principals.each do |ap|
      ap.update!(metadata: {})
    end

    result = @router.route(
      sender_name: "Vendor",
      sender_email: "vendor@example.com",
      subject: "Invoice",
      body: "Please find attached"
    )

    assert_nil result
  end

  test "returns the single principal directly without LLM call" do
    # Remove email from bob's contact so only alice remains
    agent_principals(:jennifer_bob).update!(metadata: {})

    Rails.configuration.anthropic_client.expects(:messages).never

    result = @router.route(
      sender_name: "Vendor",
      sender_email: "vendor@example.com",
      subject: "Invoice",
      body: "Please find attached"
    )

    assert_equal agent_principals(:jennifer_alice), result
  end

  test "uses LLM to pick among multiple principals" do
    mock_response = mock
    mock_content = mock
    mock_content.stubs(:text).returns("1")
    mock_response.stubs(:content).returns([mock_content])

    mock_messages = mock
    mock_messages.expects(:create).returns(mock_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(mock_messages)

    result = @router.route(
      sender_name: "Vendor",
      sender_email: "vendor@example.com",
      subject: "Sales inquiry",
      body: "We'd like to discuss a partnership"
    )

    assert_includes @agent.agent_principals.to_a, result
  end

  test "falls back to first candidate when LLM returns garbage" do
    mock_response = mock
    mock_content = mock
    mock_content.stubs(:text).returns("I think the best choice would be...")
    mock_response.stubs(:content).returns([mock_content])

    mock_messages = mock
    mock_messages.expects(:create).returns(mock_response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(mock_messages)

    result = @router.route(
      sender_name: "Vendor",
      sender_email: "vendor@example.com",
      subject: "Hello",
      body: "Hi there"
    )

    # Should fall back to first candidate with email contact
    candidates = @agent.agent_principals.includes(:user).select { |ap| ap.metadata&.dig("contact", "email").present? }
    assert_equal candidates.first, result
  end

  test "falls back to first candidate when LLM raises an error" do
    mock_messages = mock
    mock_messages.expects(:create).raises(StandardError, "API error")
    Rails.configuration.anthropic_client.stubs(:messages).returns(mock_messages)

    result = @router.route(
      sender_name: "Vendor",
      sender_email: "vendor@example.com",
      subject: "Hello",
      body: "Hi there"
    )

    candidates = @agent.agent_principals.includes(:user).select { |ap| ap.metadata&.dig("contact", "email").present? }
    assert_equal candidates.first, result
  end
end
