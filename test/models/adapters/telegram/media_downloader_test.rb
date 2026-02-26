require "test_helper"

class Adapters::Telegram::MediaDownloaderTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @downloader = Adapters::Telegram::MediaDownloader.new(bot_token: "test-token")
    @user_id = users(:alice).id
  end

  teardown do
    FileUtils.rm_rf(Rails.root.join("data", "users", @user_id.to_s))
  end

  test "returns empty array for text-only message" do
    message = { "text" => "Hello!" }
    result = @downloader.call(message, user_id: @user_id)
    assert_equal [], result
  end

  test "downloads photo and returns image attachment" do
    message = {
      "photo" => [
        { "file_id" => "small_id", "file_unique_id" => "small", "width" => 90, "height" => 90 },
        { "file_id" => "large_id", "file_unique_id" => "large", "width" => 800, "height" => 600 }
      ]
    }

    stub_telegram_file_download("large_id", "photos/file_1.jpg", "fake-jpeg-data")

    result = @downloader.call(message, user_id: @user_id)

    assert_equal 1, result.size
    att = result.first
    assert_equal "image", att.type
    assert_equal "image/jpeg", att.content_type
    assert_equal "fake-jpeg-data".bytesize, att.size
    assert File.exist?(att.file_path)
    assert_equal "fake-jpeg-data", File.read(att.file_path)
    assert_equal 800, att.metadata[:width]
    assert_equal 600, att.metadata[:height]
  end

  test "downloads document and detects PDF type" do
    message = {
      "document" => {
        "file_id" => "doc_id",
        "file_name" => "report.pdf",
        "mime_type" => "application/pdf"
      }
    }

    stub_telegram_file_download("doc_id", "documents/file_2.pdf", "fake-pdf-data")

    result = @downloader.call(message, user_id: @user_id)

    assert_equal 1, result.size
    att = result.first
    assert_equal "document", att.type
    assert_equal "application/pdf", att.content_type
    assert_equal "report.pdf", att.filename
  end

  test "downloads document and detects image type" do
    message = {
      "document" => {
        "file_id" => "img_doc_id",
        "file_name" => "diagram.png",
        "mime_type" => "image/png"
      }
    }

    stub_telegram_file_download("img_doc_id", "documents/file_3.png", "fake-png-data")

    result = @downloader.call(message, user_id: @user_id)

    assert_equal 1, result.size
    assert_equal "image", result.first.type
  end

  test "non-PDF non-image document returns file attachment" do
    message = {
      "document" => {
        "file_id" => "zip_id",
        "file_name" => "archive.zip",
        "mime_type" => "application/zip"
      }
    }

    stub_telegram_file_download("zip_id", "documents/file_4.zip", "fake-zip-data")

    result = @downloader.call(message, user_id: @user_id)

    assert_equal 1, result.size
    att = result.first
    assert_equal "file", att.type
    assert File.exist?(att.file_path)
    assert_equal "[File: archive.zip (application/zip)]", att.metadata[:description]
  end

  test "skips animated stickers" do
    message = {
      "sticker" => {
        "file_id" => "sticker_id",
        "file_unique_id" => "stk1",
        "is_animated" => true
      }
    }

    result = @downloader.call(message, user_id: @user_id)
    assert_equal [], result
  end

  test "skips video stickers" do
    message = {
      "sticker" => {
        "file_id" => "sticker_id",
        "file_unique_id" => "stk2",
        "is_video" => true
      }
    }

    result = @downloader.call(message, user_id: @user_id)
    assert_equal [], result
  end

  test "downloads static sticker as image" do
    message = {
      "sticker" => {
        "file_id" => "sticker_id",
        "file_unique_id" => "stk3",
        "is_animated" => false,
        "is_video" => false,
        "emoji" => "😀"
      }
    }

    stub_telegram_file_download("sticker_id", "stickers/file_5.webp", "fake-webp-data")

    result = @downloader.call(message, user_id: @user_id)

    assert_equal 1, result.size
    att = result.first
    assert_equal "image", att.type
    assert_equal "image/webp", att.content_type
    assert_equal "😀", att.metadata[:emoji]
  end

  test "voice message returns description without downloading" do
    message = {
      "voice" => {
        "file_id" => "voice_id",
        "duration" => 12
      }
    }

    result = @downloader.call(message, user_id: @user_id)

    assert_equal 1, result.size
    att = result.first
    assert_equal "description", att.type
    assert_nil att.file_path
    assert_equal "[Voice message, 12s]", att.metadata[:description]
  end

  test "video message returns description without downloading" do
    message = {
      "video" => {
        "file_id" => "video_id",
        "duration" => 30,
        "mime_type" => "video/mp4"
      }
    }

    result = @downloader.call(message, user_id: @user_id)

    assert_equal 1, result.size
    att = result.first
    assert_equal "description", att.type
    assert_equal "[Video, 30s]", att.metadata[:description]
  end

  test "location returns description" do
    message = {
      "location" => {
        "latitude" => 48.8566,
        "longitude" => 2.3522
      }
    }

    result = @downloader.call(message, user_id: @user_id)

    assert_equal 1, result.size
    assert_equal "[Location: 48.8566, 2.3522]", result.first.metadata[:description]
  end

  test "contact returns description" do
    message = {
      "contact" => {
        "first_name" => "John",
        "last_name" => "Doe",
        "phone_number" => "+1234567890"
      }
    }

    result = @downloader.call(message, user_id: @user_id)

    assert_equal 1, result.size
    assert_equal "[Contact: John Doe, +1234567890]", result.first.metadata[:description]
  end

  test "skips file that exceeds max size" do
    message = {
      "photo" => [
        { "file_id" => "huge_id", "file_unique_id" => "huge", "width" => 4000, "height" => 3000 }
      ]
    }

    get_file_response = stub(
      status: 200,
      body: stub(to_s: { "ok" => true, "result" => { "file_path" => "photos/huge.jpg", "file_size" => 25_000_000 } }.to_json)
    )
    HTTPX.stubs(:get).returns(get_file_response)

    result = @downloader.call(message, user_id: @user_id)
    assert_equal [], result
  end

  test "handles getFile API failure gracefully" do
    message = {
      "photo" => [
        { "file_id" => "fail_id", "file_unique_id" => "fail", "width" => 100, "height" => 100 }
      ]
    }

    error_response = stub(status: 400, body: stub(to_s: '{"ok":false}'))
    HTTPX.stubs(:get).returns(error_response)

    result = @downloader.call(message, user_id: @user_id)
    assert_equal [], result
  end

  test "handles multiple media types in one message" do
    message = {
      "photo" => [
        { "file_id" => "photo_id", "file_unique_id" => "p1", "width" => 800, "height" => 600 }
      ],
      "location" => { "latitude" => 40.7, "longitude" => -74.0 }
    }

    stub_telegram_file_download("photo_id", "photos/file_6.jpg", "photo-data")

    result = @downloader.call(message, user_id: @user_id)

    assert_equal 2, result.size
    types = result.map(&:type)
    assert_includes types, "image"
    assert_includes types, "description"
  end

  private

  def stub_telegram_file_download(file_id, telegram_path, body_content)
    get_file_response = stub(
      status: 200,
      body: stub(to_s: { "ok" => true, "result" => { "file_path" => telegram_path, "file_size" => body_content.bytesize } }.to_json)
    )
    download_response = stub(
      status: 200,
      body: stub(to_s: body_content)
    )

    HTTPX.stubs(:get)
         .with { |url, **_| url.include?("getFile") }
         .returns(get_file_response)
    HTTPX.stubs(:get)
         .with { |url, **_| url.include?("/file/bot") }
         .returns(download_response)
  end
end
