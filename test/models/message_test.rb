require 'test_helper'

class MessageTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
  end

  test 'validates role inclusion' do
    message = Message.new(
      conversation: conversations(:alice_telegram),
      user: users(:alice),
      role: 'invalid',
      content: 'test'
    )
    assert_not message.valid?
    assert_includes message.errors[:role], 'is not included in the list'
  end

  test 'chronological scope orders by created_at' do
    messages = conversations(:alice_telegram).messages.chronological
    assert_equal messages, messages.sort_by(&:created_at)
  end

  test 'unsummarized_since returns all messages when no id given' do
    messages = conversations(:alice_telegram).messages.unsummarized_since(nil)
    assert_equal 2, messages.count
  end

  test 'unsummarized_since filters by id' do
    first = messages(:alice_hello)
    unsummarized = conversations(:alice_telegram).messages.unsummarized_since(first.id)
    assert_not_includes unsummarized, first
  end

  test 'content_blocks_for_api returns plain string when no attachments' do
    message = messages(:alice_hello)
    assert_equal message.content, message.content_blocks_for_api
  end

  test 'content_blocks_for_api returns array with image block for image attachment' do
    # Create a temp file to simulate a downloaded image
    @media_dir = Dir.mktmpdir("media_test")
    file_path = File.join(@media_dir, "test_photo.jpg")
    File.binwrite(file_path, "fake-jpeg-data")

    message = conversations(:alice_telegram).messages.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      role: 'user',
      content: 'Look at this!',
      metadata: {
        "attachments" => [{
          "type" => "image",
          "file_path" => file_path,
          "content_type" => "image/jpeg",
          "filename" => "test_photo.jpg",
          "size" => 14
        }]
      }
    )

    blocks = message.content_blocks_for_api

    assert_instance_of Array, blocks
    assert_equal 2, blocks.size

    image_block = blocks.first
    assert_equal "image", image_block[:type]
    assert_equal "base64", image_block[:source][:type]
    assert_equal "image/jpeg", image_block[:source][:media_type]
    assert_equal Base64.strict_encode64("fake-jpeg-data"), image_block[:source][:data]

    text_block = blocks.last
    assert_equal "text", text_block[:type]
    assert_equal "Look at this!", text_block[:text]
  ensure
    FileUtils.rm_rf(@media_dir) if @media_dir
  end

  test 'content_blocks_for_api returns array with document block for PDF' do
    @media_dir = Dir.mktmpdir("media_test")
    file_path = File.join(@media_dir, "test_doc.pdf")
    File.binwrite(file_path, "fake-pdf-data")

    message = conversations(:alice_telegram).messages.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      role: 'user',
      content: 'Here is the report',
      metadata: {
        "attachments" => [{
          "type" => "document",
          "file_path" => file_path,
          "content_type" => "application/pdf",
          "filename" => "test_doc.pdf",
          "size" => 13
        }]
      }
    )

    blocks = message.content_blocks_for_api

    assert_instance_of Array, blocks
    assert_equal 2, blocks.size

    doc_block = blocks.first
    assert_equal "document", doc_block[:type]
    assert_equal "application/pdf", doc_block[:source][:media_type]
  ensure
    FileUtils.rm_rf(@media_dir) if @media_dir
  end

  test 'content_blocks_for_api falls back to text when file is missing' do
    message = conversations(:alice_telegram).messages.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      role: 'user',
      content: '[Photo]',
      metadata: {
        "attachments" => [{
          "type" => "image",
          "file_path" => "/nonexistent/path/photo.jpg",
          "content_type" => "image/jpeg",
          "filename" => "photo.jpg",
          "size" => 100
        }]
      }
    )

    # Should fall back to plain string since the file can't be read
    assert_equal "[Photo]", message.content_blocks_for_api
  end

  test 'content_blocks_for_api inlines text-readable file as text block' do
    @media_dir = Dir.mktmpdir("media_test")
    file_path = File.join(@media_dir, "data.csv")
    csv_content = "name,age\nAlice,30\nBob,25\n"
    File.write(file_path, csv_content)

    message = conversations(:alice_telegram).messages.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      role: 'user',
      content: '[File: data.csv (text/csv)]',
      metadata: {
        "attachments" => [{
          "type" => "file",
          "file_path" => file_path,
          "content_type" => "text/csv",
          "filename" => "data.csv",
          "size" => csv_content.bytesize
        }]
      }
    )

    blocks = message.content_blocks_for_api

    assert_instance_of Array, blocks
    assert_equal 2, blocks.size

    file_block = blocks.first
    assert_equal "text", file_block[:type]
    assert_includes file_block[:text], "Contents of data.csv"
    assert_includes file_block[:text], "Alice,30"
  ensure
    FileUtils.rm_rf(@media_dir) if @media_dir
  end

  test 'content_blocks_for_api sends text/plain file as document block' do
    @media_dir = Dir.mktmpdir("media_test")
    file_path = File.join(@media_dir, "notes.txt")
    File.write(file_path, "Hello world")

    message = conversations(:alice_telegram).messages.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      role: 'user',
      content: '[File: notes.txt (text/plain)]',
      metadata: {
        "attachments" => [{
          "type" => "file",
          "file_path" => file_path,
          "content_type" => "text/plain",
          "filename" => "notes.txt",
          "size" => 11
        }]
      }
    )

    blocks = message.content_blocks_for_api

    assert_instance_of Array, blocks
    assert_equal 2, blocks.size

    doc_block = blocks.first
    assert_equal "document", doc_block[:type]
    assert_equal "text/plain", doc_block[:source][:media_type]
    assert_equal Base64.strict_encode64("Hello world"), doc_block[:source][:data]
  ensure
    FileUtils.rm_rf(@media_dir) if @media_dir
  end

  test 'content_blocks_for_api includes binary file as descriptive text block' do
    @media_dir = Dir.mktmpdir("media_test")
    file_path = File.join(@media_dir, "report.xlsx")
    File.binwrite(file_path, "fake-xlsx-data")

    message = conversations(:alice_telegram).messages.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      role: 'user',
      content: '[File: report.xlsx (application/vnd.openxmlformats-officedocument.spreadsheetml.sheet)]',
      metadata: {
        "attachments" => [{
          "type" => "file",
          "file_path" => file_path,
          "content_type" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
          "filename" => "report.xlsx",
          "size" => 14
        }]
      }
    )

    blocks = message.content_blocks_for_api

    assert_instance_of Array, blocks
    assert_equal 2, blocks.size

    file_block = blocks.first
    assert_equal "text", file_block[:type]
    assert_includes file_block[:text], "report.xlsx"
    assert_includes file_block[:text], file_path
  ensure
    FileUtils.rm_rf(@media_dir) if @media_dir
  end

  test 'content_blocks_for_api skips description-type attachments' do
    message = conversations(:alice_telegram).messages.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      role: 'user',
      content: '[Voice message, 12s]',
      metadata: {
        "attachments" => [{
          "type" => "description",
          "file_path" => nil,
          "content_type" => "audio/ogg",
          "filename" => nil,
          "size" => nil,
          "description" => "[Voice message, 12s]"
        }]
      }
    )

    # Description-only attachments don't produce content blocks, just return text
    assert_equal "[Voice message, 12s]", message.content_blocks_for_api
  end
end
