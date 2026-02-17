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

  def read_and_encode(file_path)
    return nil if file_path.blank? || !File.exist?(file_path)

    Base64.strict_encode64(File.binread(file_path))
  rescue => e
    Rails.logger.warn("[Message] Failed to read attachment #{file_path}: #{e.message}")
    nil
  end
end
