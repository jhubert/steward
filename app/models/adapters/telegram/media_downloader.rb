module Adapters
  class Telegram
    class MediaDownloader
      MAX_FILE_SIZE = 20 * 1024 * 1024 # 20 MB (Telegram Bot API limit)

      MEDIA_TYPES = %w[photo document sticker voice audio video video_note].freeze

      Attachment = Data.define(:type, :file_path, :content_type, :filename, :size, :metadata)

      def initialize(bot_token:)
        @bot_token = bot_token
      end

      # Accepts the raw Telegram message hash.
      # Returns an array of Attachment structs (may be empty).
      def call(message, agent_id:, conversation_id:)
        attachments = []

        if message["photo"]
          att = process_photo(message["photo"], agent_id, conversation_id)
          attachments << att if att
        end

        if message["document"]
          att = process_document(message["document"], agent_id, conversation_id)
          attachments << att if att
        end

        if message["sticker"]
          att = process_sticker(message["sticker"], agent_id, conversation_id)
          attachments << att if att
        end

        if message["voice"]
          att = process_voice(message["voice"])
          attachments << att if att
        end

        if message["audio"]
          att = process_audio(message["audio"])
          attachments << att if att
        end

        if message["video"]
          att = process_video(message["video"])
          attachments << att if att
        end

        if message["video_note"]
          att = process_video_note(message["video_note"])
          attachments << att if att
        end

        if message["location"]
          att = process_location(message["location"])
          attachments << att if att
        end

        if message["contact"]
          att = process_contact(message["contact"])
          attachments << att if att
        end

        if message["venue"]
          att = process_venue(message["venue"])
          attachments << att if att
        end

        attachments
      end

      private

      def process_photo(photo_sizes, agent_id, conversation_id)
        # Pick the largest photo (last in the array)
        photo = photo_sizes.last
        return nil unless photo

        download_file(
          file_id: photo["file_id"],
          content_type: "image/jpeg",
          filename: "photo_#{photo['file_unique_id']}.jpg",
          type: "image",
          agent_id: agent_id,
          conversation_id: conversation_id,
          metadata: { width: photo["width"], height: photo["height"] }
        )
      end

      def process_document(doc, agent_id, conversation_id)
        content_type = doc["mime_type"] || "application/octet-stream"
        filename = doc["file_name"] || "document"

        download_file(
          file_id: doc["file_id"],
          content_type: content_type,
          filename: filename,
          type: detect_document_type(content_type),
          agent_id: agent_id,
          conversation_id: conversation_id,
          metadata: {}
        )
      end

      def process_sticker(sticker, agent_id, conversation_id)
        # Skip animated and video stickers — they can't be sent as images
        return nil if sticker["is_animated"] || sticker["is_video"]

        download_file(
          file_id: sticker["file_id"],
          content_type: "image/webp",
          filename: "sticker_#{sticker['file_unique_id']}.webp",
          type: "image",
          agent_id: agent_id,
          conversation_id: conversation_id,
          metadata: { emoji: sticker["emoji"] }
        )
      end

      def process_voice(voice)
        duration = voice["duration"] || 0
        Attachment.new(
          type: "description",
          file_path: nil,
          content_type: "audio/ogg",
          filename: nil,
          size: nil,
          metadata: { description: "[Voice message, #{duration}s]" }
        )
      end

      def process_audio(audio)
        title = audio["title"] || "audio"
        performer = audio["performer"]
        duration = audio["duration"] || 0
        desc = performer ? "[Audio: #{performer} — #{title}, #{duration}s]" : "[Audio: #{title}, #{duration}s]"
        Attachment.new(
          type: "description",
          file_path: nil,
          content_type: audio["mime_type"] || "audio/mpeg",
          filename: audio["file_name"],
          size: nil,
          metadata: { description: desc }
        )
      end

      def process_video(video)
        duration = video["duration"] || 0
        Attachment.new(
          type: "description",
          file_path: nil,
          content_type: video["mime_type"] || "video/mp4",
          filename: video["file_name"],
          size: nil,
          metadata: { description: "[Video, #{duration}s]" }
        )
      end

      def process_video_note(video_note)
        duration = video_note["duration"] || 0
        Attachment.new(
          type: "description",
          file_path: nil,
          content_type: "video/mp4",
          filename: nil,
          size: nil,
          metadata: { description: "[Video note, #{duration}s]" }
        )
      end

      def process_location(location)
        lat = location["latitude"]
        lon = location["longitude"]
        Attachment.new(
          type: "description",
          file_path: nil,
          content_type: nil,
          filename: nil,
          size: nil,
          metadata: { description: "[Location: #{lat}, #{lon}]" }
        )
      end

      def process_contact(contact)
        name = [contact["first_name"], contact["last_name"]].compact.join(" ")
        phone = contact["phone_number"]
        Attachment.new(
          type: "description",
          file_path: nil,
          content_type: nil,
          filename: nil,
          size: nil,
          metadata: { description: "[Contact: #{name}, #{phone}]" }
        )
      end

      def process_venue(venue)
        title = venue["title"]
        address = venue["address"]
        location = venue["location"]
        lat = location&.dig("latitude")
        lon = location&.dig("longitude")
        Attachment.new(
          type: "description",
          file_path: nil,
          content_type: nil,
          filename: nil,
          size: nil,
          metadata: { description: "[Venue: #{title}, #{address} (#{lat}, #{lon})]" }
        )
      end

      def download_file(file_id:, content_type:, filename:, type:, agent_id:, conversation_id:, metadata:)
        # Step 1: getFile to get the file_path
        get_file_response = HTTPX.get(
          "#{API_BASE}/bot#{@bot_token}/getFile",
          params: { file_id: file_id }
        )

        unless get_file_response.status == 200
          Rails.logger.warn("[MediaDownloader] getFile failed (#{get_file_response.status})")
          return nil
        end

        file_info = JSON.parse(get_file_response.body.to_s)
        telegram_file_path = file_info.dig("result", "file_path")
        file_size = file_info.dig("result", "file_size") || 0

        return nil if telegram_file_path.nil?

        if file_size > MAX_FILE_SIZE
          Rails.logger.warn("[MediaDownloader] File too large: #{file_size} bytes")
          return nil
        end

        # Step 2: Download the file
        download_response = HTTPX.get(
          "#{API_BASE}/file/bot#{@bot_token}/#{telegram_file_path}"
        )

        unless download_response.status == 200
          Rails.logger.warn("[MediaDownloader] Download failed (#{download_response.status})")
          return nil
        end

        body = download_response.body.to_s

        # Step 3: Save to disk
        dir = storage_dir(agent_id, conversation_id)
        FileUtils.mkdir_p(dir)
        safe_name = sanitize_filename(filename)
        path = File.join(dir, safe_name)
        File.binwrite(path, body)

        Attachment.new(
          type: type,
          file_path: path,
          content_type: content_type,
          filename: safe_name,
          size: body.bytesize,
          metadata: metadata
        )
      rescue => e
        Rails.logger.error("[MediaDownloader] Error downloading file: #{e.message}")
        nil
      end

      def detect_document_type(content_type)
        case content_type
        when "application/pdf"
          "document"
        when /\Aimage\//
          "image"
        else
          "description"
        end
      end

      def sanitize_filename(name)
        safe = File.basename(name.to_s)
        safe = safe.gsub(/[^a-zA-Z0-9._\-]/, "_")
        safe = "download" if safe.blank? || safe.start_with?(".")
        safe[0, 255]
      end

      def storage_dir(agent_id, conversation_id)
        Rails.root.join("data", "telegram_media", agent_id.to_s, conversation_id.to_s).to_s
      end
    end
  end
end
