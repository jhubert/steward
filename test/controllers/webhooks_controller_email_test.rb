require 'test_helper'

class WebhooksControllerEmailTest < ActionDispatch::IntegrationTest
  setup do
    @agent = agents(:jennifer)
    @workspace = workspaces(:default)
    Current.workspace = @workspace
  end

  teardown do
    # Clean up any attachment files created during tests
    data_dir = Rails.root.join("data", "users")
    Dir.glob(File.join(data_dir, "*/files/photo.jpg")).each { |f| FileUtils.rm_f(f) }
    Dir.glob(File.join(data_dir, "*/files/*_photo.jpg")).each { |f| FileUtils.rm_f(f) }
  end

  test 'email webhook creates conversation with Message-ID thread key' do
    payload = email_payload(
      from: "alice@example.com",
      from_name: "Alice",
      message_id: "<new-thread@example.com>",
      subject: "Hello Jennifer"
    )

    assert_difference 'Conversation.count', 1 do
      post '/webhooks/email', params: payload, as: :json
    end

    assert_response :ok
    conv = Conversation.last
    assert_equal "email", conv.channel
    assert_equal "<new-thread@example.com>", conv.external_thread_key
    assert_equal "Hello Jennifer", conv.metadata["email_subject"]
  end

  test 'reply in same thread routes to existing conversation' do
    # First email creates the conversation
    payload1 = email_payload(
      from: "alice@example.com",
      from_name: "Alice",
      message_id: "<msg-1@example.com>",
      subject: "Meeting Thursday"
    )
    post '/webhooks/email', params: payload1, as: :json
    assert_response :ok
    conv = Conversation.last

    # Second email (reply from Bob) in the same thread
    payload2 = email_payload(
      from: "bob@example.com",
      from_name: "Bob",
      message_id: "<msg-2@example.com>",
      references: "<msg-1@example.com>",
      in_reply_to: "<msg-1@example.com>",
      subject: "Re: Meeting Thursday",
      body: "I can do Thursday"
    )

    assert_no_difference 'Conversation.count' do
      post '/webhooks/email', params: payload2, as: :json
    end

    assert_response :ok

    # Message was added to the same conversation
    conv.reload
    assert_equal 2, conv.messages.where(role: 'user').count
    latest = conv.messages.chronological.last
    assert_equal "bob@example.com", latest.metadata["sender_email"]
  end

  test 'CC agent on thread routes correctly' do
    # Alice sends to Bob, CCs Jennifer
    payload = email_payload(
      from: "alice@example.com",
      from_name: "Alice",
      to: [
        { "Email" => "bob@example.com", "Name" => "Bob" }
      ],
      cc: [
        { "Email" => "jennifer@withstuart.com", "Name" => "Jennifer" }
      ],
      message_id: "<cc-thread@example.com>",
      subject: "Project update"
    )

    assert_difference 'Conversation.count', 1 do
      post '/webhooks/email', params: payload, as: :json
    end

    assert_response :ok
    conv = Conversation.last
    participants = conv.metadata["email_participants"]
    emails = participants.map { |p| p["email"] }
    assert_includes emails, "alice@example.com"
    assert_includes emails, "bob@example.com"
    refute_includes emails, "jennifer@withstuart.com"
  end

  test 'third-party reply to existing thread bypasses access gate' do
    # Alice (known user) starts a thread
    payload1 = email_payload(
      from: "alice@example.com",
      from_name: "Alice",
      message_id: "<gate-test@example.com>",
      subject: "Contract review"
    )
    post '/webhooks/email', params: payload1, as: :json
    conv = Conversation.last

    # Unknown person (no invite, no account) replies in the same thread
    payload2 = email_payload(
      from: "stranger@unknown.com",
      from_name: "Stranger",
      message_id: "<gate-reply@unknown.com>",
      references: "<gate-test@example.com>",
      in_reply_to: "<gate-test@example.com>",
      subject: "Re: Contract review",
      body: "Looks good to me"
    )

    assert_no_difference 'Conversation.count' do
      post '/webhooks/email', params: payload2, as: :json
    end

    assert_response :ok
    # The stranger's message was added to the existing conversation
    conv.reload
    assert_equal 2, conv.messages.where(role: 'user').count
  end

  test 'unknown sender starting new thread is rejected without invite' do
    payload = email_payload(
      from: "stranger@unknown.com",
      from_name: "Stranger",
      message_id: "<no-access@unknown.com>",
      subject: "Hi Jennifer"
    )

    assert_no_difference 'Conversation.count' do
      post '/webhooks/email', params: payload, as: :json
    end

    assert_response :ok
  end

  test 'participant list grows as new people join thread' do
    # Alice starts thread
    payload1 = email_payload(
      from: "alice@example.com",
      from_name: "Alice",
      message_id: "<grow-test@example.com>",
      subject: "Team sync"
    )
    post '/webhooks/email', params: payload1, as: :json
    conv = Conversation.last

    # Bob replies, adding Charlie to CC
    payload2 = email_payload(
      from: "bob@example.com",
      from_name: "Bob",
      to: [
        { "Email" => "jennifer@withstuart.com", "Name" => "Jennifer" },
        { "Email" => "alice@example.com", "Name" => "Alice" }
      ],
      cc: [
        { "Email" => "charlie@example.com", "Name" => "Charlie" }
      ],
      message_id: "<grow-reply@example.com>",
      references: "<grow-test@example.com>",
      in_reply_to: "<grow-test@example.com>",
      subject: "Re: Team sync",
      body: "Adding Charlie"
    )
    post '/webhooks/email', params: payload2, as: :json

    conv.reload
    emails = conv.metadata["email_participants"].map { |p| p["email"] }
    assert_includes emails, "alice@example.com"
    assert_includes emails, "bob@example.com"
    assert_includes emails, "charlie@example.com"
  end

  test 'deduplicates by Postmark MessageID' do
    payload = email_payload(
      from: "alice@example.com",
      from_name: "Alice",
      message_id: "<dedup-test@example.com>",
      postmark_id: "pm-123",
      subject: "Test"
    )

    # First delivery
    post '/webhooks/email', params: payload, as: :json
    assert_response :ok

    # Duplicate delivery
    assert_no_difference 'Message.count' do
      post '/webhooks/email', params: payload, as: :json
    end
  end

  test 'tracks last_sender_email in conversation metadata' do
    payload = email_payload(
      from: "alice@example.com",
      from_name: "Alice",
      message_id: "<sender-track@example.com>",
      subject: "Tracking test"
    )
    post '/webhooks/email', params: payload, as: :json

    conv = Conversation.last
    assert_equal "alice@example.com", conv.metadata["last_sender_email"]
  end

  test 'email with attachments stores attachment metadata on message' do
    payload = email_payload(
      from: "alice@example.com",
      from_name: "Alice",
      message_id: "<attach-test@example.com>",
      subject: "See attached",
      attachments: [
        {
          "Name" => "photo.jpg",
          "Content" => Base64.encode64("fake image data"),
          "ContentType" => "image/jpeg",
          "ContentLength" => 15
        }
      ]
    )

    assert_difference 'Message.count', 1 do
      post '/webhooks/email', params: payload, as: :json
    end

    assert_response :ok
    msg = Message.last
    assert msg.metadata["attachments"].present?
    att = msg.metadata["attachments"].first
    assert_equal "image", att["type"]
    assert_equal "image/jpeg", att["content_type"]
    assert_match(/photo\.jpg\z/, att["filename"])
  end

  test 'email with only attachment and blank body creates message' do
    payload = email_payload(
      from: "alice@example.com",
      from_name: "Alice",
      message_id: "<attach-only@example.com>",
      subject: "Photo",
      body: "",
      attachments: [
        {
          "Name" => "photo.jpg",
          "Content" => Base64.encode64("fake image data"),
          "ContentType" => "image/jpeg",
          "ContentLength" => 15
        }
      ]
    )

    assert_difference 'Message.count', 1 do
      post '/webhooks/email', params: payload, as: :json
    end

    assert_response :ok
    msg = Message.last
    assert_includes msg.content, "[Image: photo.jpg]"
  end

  test 'email with small inline CID attachment skips it' do
    payload = email_payload(
      from: "alice@example.com",
      from_name: "Alice",
      message_id: "<cid-test@example.com>",
      subject: "With signature",
      attachments: [
        {
          "Name" => "logo.png",
          "Content" => Base64.encode64("x" * 100),
          "ContentType" => "image/png",
          "ContentLength" => 100,
          "ContentID" => "logo@sig"
        }
      ]
    )

    post '/webhooks/email', params: payload, as: :json
    assert_response :ok
    msg = Message.last
    assert_nil msg.metadata["attachments"]
  end

  private

  def email_payload(from:, from_name: nil, to: nil, cc: nil, message_id:, postmark_id: nil, subject: "Test", body: "Hello", references: nil, in_reply_to: nil, attachments: nil)
    to_full = to || [{ "Email" => "jennifer@withstuart.com", "Name" => "Jennifer" }]
    cc_full = cc || []
    headers = [{ "Name" => "Message-ID", "Value" => message_id }]
    headers << { "Name" => "In-Reply-To", "Value" => in_reply_to } if in_reply_to
    headers << { "Name" => "References", "Value" => references } if references

    result = {
      "FromFull" => { "Email" => from, "Name" => from_name || from.split("@").first },
      "ToFull" => to_full,
      "CcFull" => cc_full,
      "Subject" => subject,
      "TextBody" => body,
      "StrippedTextReply" => body,
      "MessageID" => postmark_id || SecureRandom.uuid,
      "Headers" => headers
    }
    result["Attachments"] = attachments if attachments
    result
  end
end
