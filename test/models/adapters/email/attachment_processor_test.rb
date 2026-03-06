require "test_helper"

class Adapters::Email::AttachmentProcessorTest < ActiveSupport::TestCase
  setup do
    # Use a unique fake user_id per test to avoid filesystem collisions in parallel
    @user_id = rand(900_000_000..999_999_999)
    @storage_dir = Rails.root.join("data", "users", @user_id.to_s, "files").to_s
  end

  teardown do
    # Clean up the parent user dir (data/users/<id>/)
    parent = File.dirname(@storage_dir)
    FileUtils.rm_rf(parent) if Dir.exist?(parent)
  end

  test "processes image attachment" do
    raw = [postmark_attachment(name: "photo.jpg", content_type: "image/jpeg", data: "hello image")]

    result = Adapters::Email::AttachmentProcessor.call(raw, user_id: @user_id)

    assert_equal 1, result.size
    att = result.first
    assert_equal "image", att.type
    assert_equal "image/jpeg", att.content_type
    assert_equal "photo.jpg", att.filename
    assert File.exist?(att.file_path)
    assert_equal "hello image", File.read(att.file_path)
  end

  test "processes PDF as document type" do
    raw = [postmark_attachment(name: "report.pdf", content_type: "application/pdf", data: "pdf content")]

    result = Adapters::Email::AttachmentProcessor.call(raw, user_id: @user_id)

    assert_equal 1, result.size
    assert_equal "document", result.first.type
  end

  test "processes unknown type as file" do
    raw = [postmark_attachment(name: "data.csv", content_type: "text/csv", data: "a,b,c")]

    result = Adapters::Email::AttachmentProcessor.call(raw, user_id: @user_id)

    assert_equal 1, result.size
    assert_equal "file", result.first.type
  end

  test "skips small inline CID attachments" do
    # Small image with ContentID — likely a signature image
    small_data = "x" * 100
    raw = [postmark_attachment(
      name: "logo.png",
      content_type: "image/png",
      data: small_data,
      content_id: "logo@signature"
    )]

    result = Adapters::Email::AttachmentProcessor.call(raw, user_id: @user_id)

    assert_empty result
  end

  test "keeps large CID attachments" do
    # Large image with ContentID — real attachment, not a signature
    large_data = "x" * 10_000
    raw = [postmark_attachment(
      name: "screenshot.png",
      content_type: "image/png",
      data: large_data,
      content_id: "screenshot@inline"
    )]

    result = Adapters::Email::AttachmentProcessor.call(raw, user_id: @user_id)

    assert_equal 1, result.size
  end

  test "keeps attachment without ContentID regardless of size" do
    small_data = "tiny"
    raw = [postmark_attachment(name: "note.txt", content_type: "text/plain", data: small_data)]

    result = Adapters::Email::AttachmentProcessor.call(raw, user_id: @user_id)

    assert_equal 1, result.size
  end

  test "handles multiple attachments" do
    raw = [
      postmark_attachment(name: "photo.jpg", content_type: "image/jpeg", data: "img1"),
      postmark_attachment(name: "doc.pdf", content_type: "application/pdf", data: "pdf1")
    ]

    result = Adapters::Email::AttachmentProcessor.call(raw, user_id: @user_id)

    assert_equal 2, result.size
    assert_equal %w[image document], result.map(&:type)
  end

  test "handles empty attachments array" do
    assert_empty Adapters::Email::AttachmentProcessor.call([], user_id: @user_id)
    assert_empty Adapters::Email::AttachmentProcessor.call(nil, user_id: @user_id)
  end

  test "sanitizes filenames" do
    raw = [postmark_attachment(name: "my file (1).jpg", content_type: "image/jpeg", data: "data")]

    result = Adapters::Email::AttachmentProcessor.call(raw, user_id: @user_id)

    assert_equal 1, result.size
    assert_match(/\Amy_file__1_.jpg\z/, result.first.filename)
  end

  test "handles filename collisions" do
    raw = [postmark_attachment(name: "photo.jpg", content_type: "image/jpeg", data: "first")]
    Adapters::Email::AttachmentProcessor.call(raw, user_id: @user_id)

    raw2 = [postmark_attachment(name: "photo.jpg", content_type: "image/jpeg", data: "second")]
    result = Adapters::Email::AttachmentProcessor.call(raw2, user_id: @user_id)

    assert_equal 1, result.size
    refute_equal "photo.jpg", result.first.filename
    assert_match(/\d{14}_photo\.jpg/, result.first.filename)
  end

  private

  def postmark_attachment(name:, content_type:, data:, content_id: nil)
    entry = {
      "Name" => name,
      "Content" => Base64.encode64(data),
      "ContentType" => content_type,
      "ContentLength" => data.bytesize
    }
    entry["ContentID"] = content_id if content_id
    entry
  end
end
