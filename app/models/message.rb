class Message < ApplicationRecord
  include WorkspaceScoped

  belongs_to :conversation
  belongs_to :user

  validates :role, presence: true, inclusion: { in: %w[user assistant system] }
  validates :content, presence: true

  scope :chronological, -> { order(:created_at) }
  scope :recent, ->(limit = 50) { chronological.last(limit) }
  scope :unsummarized_since, lambda { |message_id|
    scope = chronological
    scope = scope.where('id > ?', message_id) if message_id
    scope
  }

  TEXT_READABLE_EXTENSIONS = %w[
    .csv .md .json .xml .log .html .htm .yml .yaml .rb .py .js .ts .jsx .tsx
    .css .scss .sass .less .sql .sh .bash .zsh .env .ini .toml .cfg .conf
    .c .cpp .h .hpp .java .go .rs .swift .kt .r .lua .pl .php
  ].freeze

  MAX_INLINE_FILE_SIZE = 100 * 1024 # 100 KB

  # Returns Anthropic-formatted content for the API.
  # For messages without attachments, returns the plain text string.
  # For messages with downloadable media, returns an array of content blocks.
  def content_blocks_for_api
    attachments = metadata&.dig("attachments")
    return content if attachments.blank?

    blocks = []

    attachments.each do |att|
      case att["type"]
      when "image"
        block = build_image_block(att)
        blocks << block if block
      when "document"
        block = build_document_block(att)
        blocks << block if block
      when "file"
        block = build_file_block(att)
        blocks << block if block
      end
      # "description" type attachments are already represented in `content` text
    end

    # Always include the text content as the last block
    return content if blocks.empty?

    blocks << { type: "text", text: content }
    blocks
  end

  private

  def build_image_block(att)
    data = read_and_encode(att["file_path"])
    return nil unless data

    {
      type: "image",
      source: {
        type: "base64",
        media_type: att["content_type"],
        data: data
      }
    }
  end

  def build_document_block(att)
    data = read_and_encode(att["file_path"])
    return nil unless data

    {
      type: "document",
      source: {
        type: "base64",
        media_type: att["content_type"],
        data: data
      }
    }
  end

  def build_file_block(att)
    file_path = att["file_path"]
    return nil if file_path.blank? || !File.exist?(file_path)

    filename = att["filename"] || File.basename(file_path)
    content_type = att["content_type"] || "application/octet-stream"
    ext = File.extname(filename).downcase

    # Strategy 1: text/plain → native document block
    if content_type == "text/plain"
      data = read_and_encode(file_path)
      return nil unless data
      return {
        type: "document",
        source: {
          type: "base64",
          media_type: "text/plain",
          data: data
        }
      }
    end

    # Strategy 2: text-readable extensions → inline as text block
    if TEXT_READABLE_EXTENSIONS.include?(ext)
      file_size = File.size(file_path)
      if file_size <= MAX_INLINE_FILE_SIZE
        text_content = File.read(file_path, encoding: "utf-8")
        return {
          type: "text",
          text: "--- Contents of #{filename} ---\n#{text_content}\n--- End of #{filename} ---"
        }
      end
    end

    # Strategy 3: binary or large files → descriptive text block with path
    file_size = File.size(file_path)
    {
      type: "text",
      text: "[File: #{filename} (#{content_type}, #{format_size(file_size)})] saved at #{file_path}"
    }
  rescue => e
    Rails.logger.warn("[Message] Failed to read file attachment #{att['file_path']}: #{e.message}")
    nil
  end

  def format_size(bytes)
    if bytes < 1024
      "#{bytes} B"
    elsif bytes < 1024 * 1024
      "#{(bytes / 1024.0).round(1)} KB"
    else
      "#{(bytes / (1024.0 * 1024)).round(1)} MB"
    end
  end

  def read_and_encode(file_path)
    return nil if file_path.blank? || !File.exist?(file_path)

    Base64.strict_encode64(File.binread(file_path))
  rescue => e
    Rails.logger.warn("[Message] Failed to read attachment #{file_path}: #{e.message}")
    nil
  end
end
