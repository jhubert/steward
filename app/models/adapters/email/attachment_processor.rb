module Adapters
  class Email
    class AttachmentProcessor
      MAX_FILE_SIZE = 20 * 1024 * 1024 # 20 MB
      MIN_CID_SIZE = 5 * 1024          # 5 KB — skip tiny inline CID images (signatures)

      # Reuse the same Attachment struct as Telegram::MediaDownloader
      Attachment = Adapters::Telegram::MediaDownloader::Attachment

      # Accepts Postmark's Attachments array (base64-encoded files).
      # Returns an array of Attachment structs.
      def self.call(raw_attachments, user_id:)
        return [] if raw_attachments.blank?

        attachments = []

        raw_attachments.each do |entry|
          att = process_entry(entry, user_id: user_id)
          attachments << att if att
        end

        attachments
      end

      def self.process_entry(entry, user_id:)
        content_type = entry["ContentType"].to_s
        filename = entry["Name"].to_s.presence || "attachment"
        content_id = entry["ContentID"].to_s.presence
        content_b64 = entry["Content"].to_s
        content_length = entry["ContentLength"].to_i

        # Use ContentLength if available, otherwise estimate from base64
        estimated_size = content_length > 0 ? content_length : (content_b64.length * 3 / 4)

        # Skip small inline CID attachments (email signature images, tracking pixels)
        if content_id.present? && estimated_size < MIN_CID_SIZE
          return nil
        end

        if estimated_size > MAX_FILE_SIZE
          Rails.logger.warn("[Email::AttachmentProcessor] Attachment too large: #{estimated_size} bytes (#{filename})")
          return nil
        end

        # Decode base64 content
        begin
          data = Base64.decode64(content_b64)
        rescue => e
          Rails.logger.warn("[Email::AttachmentProcessor] Failed to decode attachment: #{e.message}")
          return nil
        end

        return nil if data.blank?

        # Save to disk
        dir = storage_dir(user_id)
        FileUtils.mkdir_p(dir)
        safe_name = sanitize_filename(filename)
        path = File.join(dir, safe_name)

        # Handle filename collisions
        if File.exist?(path)
          ext = File.extname(safe_name)
          base = File.basename(safe_name, ext)
          safe_name = "#{Time.current.strftime('%Y%m%d%H%M%S')}_#{base}#{ext}"
          path = File.join(dir, safe_name)
        end

        File.binwrite(path, data)

        type = classify_type(content_type)

        Attachment.new(
          type: type,
          file_path: path,
          content_type: content_type,
          filename: safe_name,
          size: data.bytesize,
          metadata: {}
        )
      rescue => e
        Rails.logger.error("[Email::AttachmentProcessor] Error processing attachment: #{e.message}")
        nil
      end

      def self.classify_type(content_type)
        case content_type
        when /\Aimage\//
          "image"
        when "application/pdf"
          "document"
        else
          "file"
        end
      end

      def self.sanitize_filename(name)
        safe = File.basename(name.to_s)
        safe = safe.gsub(/[^a-zA-Z0-9._\-]/, "_")
        safe = "attachment" if safe.blank? || safe.start_with?(".")
        safe[0, 255]
      end

      def self.storage_dir(user_id)
        Rails.root.join("data", "users", user_id.to_s, "files").to_s
      end

      private_class_method :process_entry, :classify_type, :sanitize_filename, :storage_dir
    end
  end
end
