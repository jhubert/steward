require 'test_helper'

class Adapters::EmailTest < ActiveSupport::TestCase
  setup do
    @adapter = Adapters::Email.new(server_token: 'test-server-token')
  end

  test 'channel returns email' do
    assert_equal 'email', @adapter.channel
  end

  test 'normalize extracts sender, content, and agent_handle from Postmark payload' do
    raw = postmark_payload

    result = @adapter.normalize(raw)

    assert_equal 'email', result[:user_external_key]
    assert_equal 'sender@example.com', result[:user_external_value]
    assert_equal 'Sender Name', result[:user_name]
    assert_equal 'sender@example.com', result[:external_thread_key]
    assert_equal 'This is the stripped reply', result[:content]
    assert_equal 'jennifer', result[:agent_handle]
  end

  test 'normalize prefers StrippedTextReply over TextBody' do
    raw = postmark_payload
    result = @adapter.normalize(raw)

    assert_equal 'This is the stripped reply', result[:content]
  end

  test 'normalize falls back to TextBody when StrippedTextReply is blank' do
    raw = postmark_payload("StrippedTextReply" => "")
    result = @adapter.normalize(raw)

    assert_equal 'Full text body including quoted text', result[:content]
  end

  test 'normalize returns nil when FromFull missing' do
    raw = postmark_payload.except("FromFull")
    assert_nil @adapter.normalize(raw)
  end

  test 'normalize returns nil when no matching To address' do
    raw = postmark_payload(
      "ToFull" => [{ "Email" => "someone@otherdomain.com", "Name" => "Someone" }]
    )
    assert_nil @adapter.normalize(raw)
  end

  test 'normalize extracts threading metadata' do
    raw = postmark_payload
    result = @adapter.normalize(raw)

    assert_equal 'abc-123', result[:metadata]["email_message_id"]
    assert_equal 'Hello Jennifer', result[:metadata]["email_subject"]
    assert_equal '<original@example.com>', result[:metadata]["email_original_message_id"]
  end

  test 'normalize uses email local part as name when FromFull Name is blank' do
    raw = postmark_payload("FromFull" => { "Email" => "sender@example.com", "Name" => "" })
    result = @adapter.normalize(raw)

    assert_equal 'sender', result[:user_name]
  end

  test 'normalize downcases sender email' do
    raw = postmark_payload("FromFull" => { "Email" => "Sender@Example.COM", "Name" => "Test" })
    result = @adapter.normalize(raw)

    assert_equal 'sender@example.com', result[:user_external_value]
    assert_equal 'sender@example.com', result[:external_thread_key]
  end

  test 'send_typing returns nil' do
    assert_nil @adapter.send_typing(nil)
  end

  test 'send_reply calls Postmark API with correct body' do
    as_workspace(:default)
    conversation = conversations(:alice_jennifer_email)
    message = conversation.messages.create!(
      workspace: conversation.workspace,
      user: conversation.user,
      role: 'assistant',
      content: 'Hello from Jennifer!'
    )

    mock_response = stub(status: 200, body: '{"MessageID": "outbound-456"}')
    HTTPX.expects(:post).with(
      "https://api.postmarkapp.com/email",
      has_entries(json: has_entries(
        "From" => "jennifer@withstuart.com",
        "To" => "alice@example.com",
        "Subject" => "Re: Hello Jennifer",
        "TextBody" => "Hello from Jennifer!"
      ))
    ).returns(mock_response)

    @adapter.send_reply(conversation, message)

    message.reload
    assert_equal 'outbound-456', message.metadata['postmark_message_id']
  end

  test 'send_reply raises DeliveryError on non-200' do
    as_workspace(:default)
    conversation = conversations(:alice_jennifer_email)
    message = conversation.messages.create!(
      workspace: conversation.workspace,
      user: conversation.user,
      role: 'assistant',
      content: 'Test'
    )

    mock_response = stub(status: 422, body: '{"ErrorCode": 300}')
    HTTPX.expects(:post).returns(mock_response)

    assert_raises(Adapters::DeliveryError) do
      @adapter.send_reply(conversation, message)
    end
  end

  test 'send_reply includes In-Reply-To and References headers' do
    as_workspace(:default)
    conversation = conversations(:alice_jennifer_email)
    message = conversation.messages.create!(
      workspace: conversation.workspace,
      user: conversation.user,
      role: 'assistant',
      content: 'Reply text'
    )

    mock_response = stub(status: 200, body: '{"MessageID": "out-789"}')
    HTTPX.expects(:post).with do |_url, opts|
      headers = opts[:json]["Headers"]
      headers.any? { |h| h["Name"] == "In-Reply-To" && h["Value"] == "<original-123@example.com>" } &&
        headers.any? { |h| h["Name"] == "References" && h["Value"] == "<original-123@example.com>" }
    end.returns(mock_response)

    @adapter.send_reply(conversation, message)
  end

  test 'send_reply does not double-prepend Re: to subject' do
    as_workspace(:default)
    conversation = conversations(:alice_jennifer_email)
    conversation.update!(metadata: conversation.metadata.merge("email_subject" => "Re: Already a reply"))

    message = conversation.messages.create!(
      workspace: conversation.workspace,
      user: conversation.user,
      role: 'assistant',
      content: 'Another reply'
    )

    mock_response = stub(status: 200, body: '{"MessageID": "out-101"}')
    HTTPX.expects(:post).with do |_url, opts|
      opts[:json]["Subject"] == "Re: Already a reply"
    end.returns(mock_response)

    @adapter.send_reply(conversation, message)
  end

  test 'send_welcome_email sends without threading headers' do
    mock_response = stub(status: 200, body: '{"MessageID": "welcome-123"}')
    HTTPX.expects(:post).with(
      "https://api.postmarkapp.com/email",
      has_entries(json: has_entries(
        "From" => "stuart@withstuart.com",
        "To" => "newuser@example.com",
        "Subject" => "Welcome to Stuart",
        "TextBody" => "Welcome!",
        "MessageStream" => "outbound"
      ))
    ).returns(mock_response)

    result = @adapter.send_welcome_email(
      from_handle: "stuart",
      to_email: "newuser@example.com",
      subject: "Welcome to Stuart",
      body: "Welcome!"
    )

    assert_equal "welcome-123", result
  end

  test 'send_welcome_email does not include Headers key' do
    mock_response = stub(status: 200, body: '{"MessageID": "welcome-456"}')
    HTTPX.expects(:post).with do |_url, opts|
      !opts[:json].key?("Headers")
    end.returns(mock_response)

    @adapter.send_welcome_email(
      from_handle: "stuart",
      to_email: "test@example.com",
      subject: "Hi",
      body: "Hello"
    )
  end

  test 'send_welcome_email raises DeliveryError on failure' do
    mock_response = stub(status: 422, body: '{"ErrorCode": 300}')
    HTTPX.expects(:post).returns(mock_response)

    assert_raises(Adapters::DeliveryError) do
      @adapter.send_welcome_email(
        from_handle: "stuart",
        to_email: "test@example.com",
        subject: "Hi",
        body: "Hello"
      )
    end
  end

  private

  def postmark_payload(overrides = {})
    {
      "FromFull" => { "Email" => "sender@example.com", "Name" => "Sender Name" },
      "ToFull" => [{ "Email" => "jennifer@withstuart.com", "Name" => "Jennifer" }],
      "Subject" => "Hello Jennifer",
      "TextBody" => "Full text body including quoted text",
      "StrippedTextReply" => "This is the stripped reply",
      "MessageID" => "abc-123",
      "Headers" => [
        { "Name" => "Message-ID", "Value" => "<original@example.com>" },
        { "Name" => "In-Reply-To", "Value" => "<previous@example.com>" },
        { "Name" => "References", "Value" => "<previous@example.com>" }
      ]
    }.merge(overrides)
  end
end
