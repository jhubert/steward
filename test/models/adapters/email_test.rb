require 'test_helper'

class Adapters::EmailTest < ActiveSupport::TestCase
  setup do
    @adapter = Adapters::Email.new(server_token: 'test-server-token')
  end

  test 'channel returns email' do
    assert_equal 'email', @adapter.channel
  end

  # --- normalize: basic extraction ---

  test 'normalize extracts sender, content, and agent_handle from Postmark payload' do
    raw = postmark_payload

    result = @adapter.normalize(raw)

    assert_equal 'email', result[:user_external_key]
    assert_equal 'sender@example.com', result[:user_external_value]
    assert_equal 'Sender Name', result[:user_name]
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

  test 'normalize returns nil when no matching To or Cc address' do
    raw = postmark_payload(
      "ToFull" => [{ "Email" => "someone@otherdomain.com", "Name" => "Someone" }],
      "CcFull" => []
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
  end

  test 'normalize includes sender_email and sender_name in metadata' do
    raw = postmark_payload
    result = @adapter.normalize(raw)

    assert_equal 'sender@example.com', result[:metadata]["sender_email"]
    assert_equal 'Sender Name', result[:metadata]["sender_name"]
  end

  # --- normalize: CC scanning ---

  test 'normalize finds agent handle in CcFull when not in ToFull' do
    raw = postmark_payload(
      "ToFull" => [{ "Email" => "someone@otherdomain.com", "Name" => "Someone" }],
      "CcFull" => [{ "Email" => "jennifer@withstuart.com", "Name" => "Jennifer" }]
    )
    result = @adapter.normalize(raw)

    assert_equal 'jennifer', result[:agent_handle]
  end

  test 'normalize prefers ToFull over CcFull for agent handle' do
    raw = postmark_payload(
      "ToFull" => [{ "Email" => "jennifer@withstuart.com", "Name" => "Jennifer" }],
      "CcFull" => [{ "Email" => "stuart@withstuart.com", "Name" => "Stuart" }]
    )
    result = @adapter.normalize(raw)

    assert_equal 'jennifer', result[:agent_handle]
  end

  # --- normalize: thread key derivation ---

  test 'normalize derives thread key from References header (first Message-ID)' do
    raw = postmark_payload(
      "Headers" => [
        { "Name" => "Message-ID", "Value" => "<msg-3@example.com>" },
        { "Name" => "References", "Value" => "<root@example.com> <msg-2@example.com>" }
      ]
    )
    result = @adapter.normalize(raw)

    assert_equal '<root@example.com>', result[:external_thread_key]
  end

  test 'normalize derives thread key from In-Reply-To when no References' do
    raw = postmark_payload(
      "Headers" => [
        { "Name" => "Message-ID", "Value" => "<msg-2@example.com>" },
        { "Name" => "In-Reply-To", "Value" => "<msg-1@example.com>" }
      ]
    )
    result = @adapter.normalize(raw)

    assert_equal '<msg-1@example.com>', result[:external_thread_key]
  end

  test 'normalize uses own Message-ID as thread key for new threads' do
    raw = postmark_payload(
      "Headers" => [
        { "Name" => "Message-ID", "Value" => "<new-thread@example.com>" }
      ]
    )
    result = @adapter.normalize(raw)

    assert_equal '<new-thread@example.com>', result[:external_thread_key]
  end

  test 'normalize generates UUID thread key when no headers at all' do
    raw = postmark_payload("Headers" => [])
    result = @adapter.normalize(raw)

    # Should be a UUID format
    assert_match(/\A[0-9a-f-]{36}\z/, result[:external_thread_key])
  end

  test 'normalize handles case-insensitive header names (Message-Id vs Message-ID)' do
    raw = postmark_payload(
      "Headers" => [
        { "Name" => "Message-Id", "Value" => "<apple-mail@icloud.com>" },
        { "Name" => "in-reply-to", "Value" => "<prev@example.com>" },
        { "Name" => "references", "Value" => "<root@example.com> <prev@example.com>" }
      ]
    )
    result = @adapter.normalize(raw)

    assert_equal '<apple-mail@icloud.com>', result[:metadata]["email_original_message_id"]
    assert_equal '<prev@example.com>', result[:metadata]["email_in_reply_to"]
    assert_equal '<root@example.com> <prev@example.com>', result[:metadata]["email_references"]
    assert_equal '<root@example.com>', result[:external_thread_key]
  end

  # --- normalize: participant collection ---

  test 'normalize collects participants from From, To, and Cc' do
    raw = postmark_payload(
      "FromFull" => { "Email" => "alice@example.com", "Name" => "Alice" },
      "ToFull" => [
        { "Email" => "jennifer@withstuart.com", "Name" => "Jennifer" },
        { "Email" => "bob@example.com", "Name" => "Bob" }
      ],
      "CcFull" => [
        { "Email" => "charlie@example.com", "Name" => "Charlie" }
      ]
    )
    result = @adapter.normalize(raw)
    participants = result[:participants]

    emails = participants.map { |p| p["email"] }
    assert_includes emails, "alice@example.com"
    assert_includes emails, "bob@example.com"
    assert_includes emails, "charlie@example.com"
    refute_includes emails, "jennifer@withstuart.com"
  end

  test 'normalize deduplicates participants' do
    raw = postmark_payload(
      "FromFull" => { "Email" => "alice@example.com", "Name" => "Alice" },
      "ToFull" => [
        { "Email" => "jennifer@withstuart.com", "Name" => "Jennifer" },
        { "Email" => "alice@example.com", "Name" => "Alice Again" }
      ]
    )
    result = @adapter.normalize(raw)
    emails = result[:participants].map { |p| p["email"] }

    assert_equal 1, emails.count("alice@example.com")
  end

  # --- send_typing ---

  test 'send_typing returns nil' do
    assert_nil @adapter.send_typing(nil)
  end

  # --- send_reply ---

  test 'send_reply sends to last sender with participants as Cc' do
    as_workspace(:default)
    conversation = conversations(:alice_jennifer_email)
    conversation.update!(metadata: conversation.metadata.merge(
      "last_sender_email" => "alice@example.com",
      "email_participants" => [
        { "email" => "alice@example.com", "name" => "Alice" },
        { "email" => "bob@example.com", "name" => "Bob" }
      ]
    ))
    message = conversation.messages.create!(
      workspace: conversation.workspace,
      user: conversation.user,
      role: 'assistant',
      content: 'Hello from Jennifer!'
    )

    mock_response = stub(status: 200, body: '{"MessageID": "outbound-456"}')
    HTTPX.expects(:post).with do |_url, opts|
      json = opts[:json]
      json["From"] == "jennifer@withstuart.com" &&
        json["To"] == "alice@example.com" &&
        json["Cc"] == "bob@example.com" &&
        json["Subject"] == "Re: Hello Jennifer" &&
        json["HtmlBody"].include?("Hello from Jennifer!")
    end.returns(mock_response)

    @adapter.send_reply(conversation, message)

    message.reload
    assert_equal 'outbound-456', message.metadata['postmark_message_id']
  end

  test 'send_reply falls back to conversation owner email when no last sender' do
    as_workspace(:default)
    conversation = conversations(:alice_jennifer_email)
    # No last_sender_email set, no participants
    message = conversation.messages.create!(
      workspace: conversation.workspace,
      user: conversation.user,
      role: 'assistant',
      content: 'Test reply'
    )

    mock_response = stub(status: 200, body: '{"MessageID": "outbound-789"}')
    HTTPX.expects(:post).with do |_url, opts|
      opts[:json]["To"] == "alice@example.com"
    end.returns(mock_response)

    @adapter.send_reply(conversation, message)
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

  test 'send_reply includes threading headers from conversation metadata' do
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
        headers.any? { |h| h["Name"] == "References" }
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

  test 'send_reply tracks outbound Message-ID in conversation metadata' do
    as_workspace(:default)
    conversation = conversations(:alice_jennifer_email)
    message = conversation.messages.create!(
      workspace: conversation.workspace,
      user: conversation.user,
      role: 'assistant',
      content: 'Test tracking'
    )

    mock_response = stub(status: 200, body: '{"MessageID": "tracked-123"}')
    HTTPX.expects(:post).returns(mock_response)

    @adapter.send_reply(conversation, message)

    conversation.reload
    assert_equal "<tracked-123@mtasv.net>", conversation.metadata["last_outbound_message_id"]
    assert_includes conversation.metadata["email_references_chain"], "<tracked-123@mtasv.net>"
  end

  # --- send_welcome_email ---

  test 'send_welcome_email sends without threading headers' do
    mock_response = stub(status: 200, body: '{"MessageID": "welcome-123"}')
    HTTPX.expects(:post).with do |_url, opts|
      json = opts[:json]
      json["From"] == "stuart@withstuart.com" &&
        json["To"] == "newuser@example.com" &&
        json["Subject"] == "Welcome to Stuart" &&
        json["TextBody"] == "Welcome!" &&
        json["HtmlBody"].present? &&
        json["MessageStream"] == "outbound"
    end.returns(mock_response)

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

  # --- send_new_email ---

  test 'send_new_email sends email and returns MessageID' do
    mock_response = stub(status: 200, body: '{"MessageID": "new-email-123"}')
    HTTPX.expects(:post).with do |_url, opts|
      json = opts[:json]
      json["From"] == "jennifer@withstuart.com" &&
        json["To"] == "client@example.com" &&
        json["Subject"] == "Regarding the contract" &&
        json["TextBody"] == "Hello, here is the contract." &&
        json["HtmlBody"].include?("Hello, here is the contract.")
    end.returns(mock_response)

    result = @adapter.send_new_email(
      from_handle: "jennifer",
      to: "client@example.com",
      subject: "Regarding the contract",
      body: "Hello, here is the contract."
    )

    assert_equal "new-email-123", result
  end

  test 'send_new_email includes Cc when provided' do
    mock_response = stub(status: 200, body: '{"MessageID": "cc-email-123"}')
    HTTPX.expects(:post).with do |_url, opts|
      opts[:json]["Cc"] == "boss@example.com"
    end.returns(mock_response)

    @adapter.send_new_email(
      from_handle: "jennifer",
      to: "client@example.com",
      cc: "boss@example.com",
      subject: "Re: Contract",
      body: "Follow up."
    )
  end

  private

  def postmark_payload(overrides = {})
    {
      "FromFull" => { "Email" => "sender@example.com", "Name" => "Sender Name" },
      "ToFull" => [{ "Email" => "jennifer@withstuart.com", "Name" => "Jennifer" }],
      "CcFull" => [],
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
