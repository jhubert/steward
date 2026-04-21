require "test_helper"
require "base64"
require "json"

class Tools::GmailReaderTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @agent = agents(:jennifer)
    # Give Jennifer a GOG env so own_gog_env returns something.
    @agent.stubs(:own_gog_env).returns({
      "XDG_CONFIG_HOME" => "/tmp/gog",
      "GOG_KEYRING_PASSWORD" => "pw",
      "GOG_KEYRING_BACKEND" => "file",
      "GOG_ACCOUNT" => "jennifer@example.com"
    })
  end

  test "returns error when thread_id is blank" do
    result = Tools::GmailReader.new(@agent).call(thread_id: "")
    refute result.ok?
    assert_match(/thread_id is required/, result.error)
  end

  test "returns error when agent has no GOG env" do
    @agent.unstub(:own_gog_env)
    @agent.stubs(:own_gog_env).returns(nil)

    result = Tools::GmailReader.new(@agent).call(thread_id: "abc123")
    refute result.ok?
    assert_match(/does not have GOG configured/, result.error)
  end

  test "returns error when gog command fails" do
    status = stub(success?: false)
    Open3.stubs(:capture3).returns(["", "auth expired", status])

    result = Tools::GmailReader.new(@agent).call(thread_id: "abc123")
    refute result.ok?
    assert_match(/gog failed.*auth expired/, result.error)
  end

  test "returns error when gog output is not JSON" do
    status = stub(success?: true)
    Open3.stubs(:capture3).returns(["not json", "", status])

    result = Tools::GmailReader.new(@agent).call(thread_id: "abc123")
    refute result.ok?
    assert_match(/Could not parse gog output as JSON/, result.error)
  end

  test "returns error when thread has no messages" do
    stub_thread_response("abc123", [])
    result = Tools::GmailReader.new(@agent).call(thread_id: "abc123")
    refute result.ok?
    assert_match(/Thread not found or empty/, result.error)
  end

  test "parses a simple single-part plaintext thread" do
    body = "Hi Jennifer,\n\nHope you're well.\n\nTom"
    stub_thread_response("abc123", [
      build_message(
        headers: {
          "From" => "Tom Gaston <tom@example.com>",
          "To" => "Jennifer Lawson <jennifer@example.com>",
          "Subject" => "A question"
        },
        internal_date_ms: 1_776_720_000_000, # Mon Apr 20 2026 ~14:20 PDT
        mime: "text/plain",
        body_text: body
      )
    ])

    result = Tools::GmailReader.new(@agent).call(thread_id: "abc123")
    assert result.ok?, "expected ok? but got error: #{result.error}"
    assert_includes result.content, "Thread: A question (1 message)"
    assert_includes result.content, "Thread ID: abc123"
    assert_includes result.content, "--- Message 1 —"
    assert_includes result.content, "From:    Tom Gaston <tom@example.com>"
    assert_includes result.content, "Subject: A question"
    assert_includes result.content, "Hi Jennifer,"
    assert_includes result.content, "Hope you're well."
  end

  test "decodes HTML body and strips tags" do
    html = "<p>Hi Tom,</p><p>Here are the <strong>answers</strong>:</p><ul><li>One</li><li>Two</li></ul>"
    stub_thread_response("abc123", [
      build_message(
        headers: { "From" => "jenn@example.com", "Subject" => "Answers" },
        mime: "text/html",
        body_text: html
      )
    ])

    result = Tools::GmailReader.new(@agent).call(thread_id: "abc123")
    assert result.ok?
    assert_includes result.content, "Hi Tom,"
    assert_includes result.content, "Here are the answers:"
    assert_includes result.content, "• One"
    assert_includes result.content, "• Two"
    refute_includes result.content, "<p>"
    refute_includes result.content, "<strong>"
  end

  test "prefers text/plain part over text/html in multipart" do
    plain = "Plain text version"
    html = "<p>HTML version</p>"
    stub_thread_response("abc123", [
      build_multipart_message(
        headers: { "From" => "a@example.com", "Subject" => "Alt" },
        plain_text: plain,
        html_text: html
      )
    ])

    result = Tools::GmailReader.new(@agent).call(thread_id: "abc123")
    assert result.ok?
    assert_includes result.content, "Plain text version"
    refute_includes result.content, "HTML version"
  end

  test "strips Gmail-style quoted history" do
    body = "Here's my reply.\n\nOn Mon, Apr 21, 2026 at 2:43 PM Tom Gaston wrote:\n> Original question\n> with more lines"
    stub_thread_response("abc123", [
      build_message(
        headers: { "From" => "jenn@example.com", "Subject" => "Re: Q" },
        mime: "text/plain",
        body_text: body
      )
    ])

    result = Tools::GmailReader.new(@agent).call(thread_id: "abc123")
    assert result.ok?
    assert_includes result.content, "Here's my reply."
    refute_includes result.content, "On Mon, Apr 21"
    refute_includes result.content, "Original question"
  end

  test "strips Outlook-style quoted history" do
    body = "My reply.\n\nFrom: Jennifer Lawson\nSent: Tuesday, April 21\nTo: Tom\nSubject: RE: Q\n\nOriginal content here"
    stub_thread_response("abc123", [
      build_message(
        headers: { "From" => "tom@example.com", "Subject" => "RE: Q" },
        mime: "text/plain",
        body_text: body
      )
    ])

    result = Tools::GmailReader.new(@agent).call(thread_id: "abc123")
    assert result.ok?
    assert_includes result.content, "My reply."
    refute_includes result.content, "Original content here"
  end

  test "handles multi-message thread with correct ordering" do
    stub_thread_response("abc123", [
      build_message(headers: { "From" => "tom@example.com", "Subject" => "Q" }, mime: "text/plain", body_text: "First message"),
      build_message(headers: { "From" => "jenn@example.com", "Subject" => "RE: Q" }, mime: "text/plain", body_text: "Second message"),
      build_message(headers: { "From" => "tom@example.com", "Subject" => "RE: Q" }, mime: "text/plain", body_text: "Third message")
    ])

    result = Tools::GmailReader.new(@agent).call(thread_id: "abc123")
    assert result.ok?
    assert_includes result.content, "(3 messages)"

    first_idx = result.content.index("First message")
    second_idx = result.content.index("Second message")
    third_idx = result.content.index("Third message")
    assert first_idx < second_idx
    assert second_idx < third_idx
  end

  test "falls back to snippet when body is missing" do
    msg = {
      "payload" => { "headers" => [{ "name" => "Subject", "value" => "No body" }] },
      "snippet" => "preview text",
      "internalDate" => "1776720000000",
      "labelIds" => ["INBOX"]
    }
    stub_thread_response("abc123", [msg])

    result = Tools::GmailReader.new(@agent).call(thread_id: "abc123")
    assert result.ok?
    assert_includes result.content, "preview text"
  end

  private

  def stub_thread_response(thread_id, messages)
    response = { "thread" => { "id" => thread_id, "messages" => messages } }.to_json
    status = stub(success?: true)
    Open3.stubs(:capture3).returns([response, "", status])
  end

  def build_message(headers:, mime: "text/plain", body_text: "", internal_date_ms: 1_776_720_000_000, label_ids: ["INBOX"])
    encoded = Base64.urlsafe_encode64(body_text, padding: false)
    {
      "id" => SecureRandom.hex(8),
      "internalDate" => internal_date_ms.to_s,
      "labelIds" => label_ids,
      "snippet" => body_text[0, 50],
      "payload" => {
        "mimeType" => mime,
        "headers" => headers.map { |k, v| { "name" => k, "value" => v } },
        "body" => { "data" => encoded, "size" => body_text.bytesize }
      }
    }
  end

  def build_multipart_message(headers:, plain_text:, html_text:, internal_date_ms: 1_776_720_000_000)
    {
      "id" => SecureRandom.hex(8),
      "internalDate" => internal_date_ms.to_s,
      "labelIds" => ["INBOX"],
      "snippet" => plain_text[0, 50],
      "payload" => {
        "mimeType" => "multipart/alternative",
        "headers" => headers.map { |k, v| { "name" => k, "value" => v } },
        "body" => {},
        "parts" => [
          { "mimeType" => "text/plain", "body" => { "data" => Base64.urlsafe_encode64(plain_text, padding: false) } },
          { "mimeType" => "text/html", "body" => { "data" => Base64.urlsafe_encode64(html_text, padding: false) } }
        ]
      }
    }
  end
end
