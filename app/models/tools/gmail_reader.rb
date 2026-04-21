require "base64"
require "json"
require "open3"

module Tools
  # Fetches and parses a Gmail thread using the agent's own GOG credentials,
  # returning a clean plaintext digest. Exists so agents don't have to parse
  # nested JSON with base64-encoded bodies themselves — which is where
  # hallucination risk lives.
  class GmailReader
    GOG_BINARY = "/usr/local/bin/gog".freeze

    Result = Struct.new(:ok?, :content, :error, keyword_init: true)

    def initialize(agent)
      @agent = agent
    end

    def call(thread_id:, timezone: nil)
      return Result.new(ok?: false, error: "thread_id is required") if thread_id.to_s.strip.empty?

      gog_env = @agent.own_gog_env
      return Result.new(ok?: false, error: "Agent does not have GOG configured") unless gog_env

      stdout, stderr, status = Open3.capture3(gog_env,
        GOG_BINARY, "gmail", "thread", "get", thread_id.to_s, "--full", "--json", "--no-input")

      unless status.success?
        err = stderr.presence || stdout
        return Result.new(ok?: false, error: "gog failed: #{err.to_s.truncate(500)}")
      end

      data = JSON.parse(stdout)
      thread = data["thread"] || {}
      messages = thread["messages"] || []
      return Result.new(ok?: false, error: "Thread not found or empty") if messages.empty?

      tz = ActiveSupport::TimeZone[timezone || @agent.settings&.dig("timezone") || "Pacific Time (US & Canada)"]
      subject = first_header(messages.first, "Subject") || "(no subject)"

      parts = ["Thread: #{subject} (#{messages.size} message#{'s' if messages.size != 1})"]
      parts << "Thread ID: #{thread_id}"

      messages.each_with_index do |msg, i|
        parts << format_message(msg, i + 1, tz)
      end

      Result.new(ok?: true, content: parts.join("\n\n"))
    rescue JSON::ParserError => e
      Result.new(ok?: false, error: "Could not parse gog output as JSON: #{e.message}")
    rescue => e
      Result.new(ok?: false, error: "GmailReader error: #{e.class}: #{e.message}")
    end

    private

    def format_message(msg, index, tz)
      headers = (msg["payload"]&.dig("headers") || []).to_h { |h| [h["name"].to_s.downcase, h["value"]] }
      date = Time.at(msg["internalDate"].to_i / 1000).in_time_zone(tz).strftime("%a %b %-d, %Y %-I:%M %p %Z") rescue headers["date"]

      sections = []
      sections << "--- Message #{index} — #{date} ---"
      sections << "From:    #{headers['from']}"       if headers["from"]
      sections << "To:      #{headers['to']}"         if headers["to"]
      sections << "Cc:      #{headers['cc']}"         if headers["cc"]
      sections << "Subject: #{headers['subject']}"    if headers["subject"]
      sections << "Labels:  #{(msg['labelIds'] || []).join(', ')}" if msg["labelIds"].is_a?(Array) && msg["labelIds"].any?

      body = extract_body(msg["payload"]) || msg["snippet"].to_s
      body = strip_quoted_history(body)
      body = body.strip

      sections << "Body:"
      sections << (body.presence || "(empty)")
      sections.join("\n")
    end

    # Walk the MIME tree. Prefer text/plain; fall back to text/html (stripped).
    def extract_body(payload)
      return nil unless payload

      plain = find_part(payload, "text/plain")
      return decode_part(plain) if plain

      html = find_part(payload, "text/html")
      return html_to_text(decode_part(html)) if html

      # Non-multipart with direct body
      if payload["body"]&.dig("data")
        raw = decode_base64url(payload["body"]["data"])
        mime = payload["mimeType"].to_s
        return mime.include?("html") ? html_to_text(raw) : raw
      end

      nil
    end

    def find_part(payload, mime_type)
      return payload if payload["mimeType"] == mime_type && payload["body"]&.dig("data")
      (payload["parts"] || []).each do |p|
        found = find_part(p, mime_type)
        return found if found
      end
      nil
    end

    def decode_part(part)
      data = part&.dig("body", "data")
      data ? decode_base64url(data) : ""
    end

    def decode_base64url(str)
      raw = begin
        Base64.urlsafe_decode64(str.to_s)
      rescue ArgumentError
        # Some senders pad oddly; try regular decode
        Base64.decode64(str.to_s.tr("-_", "+/"))
      end
      raw.force_encoding("UTF-8").scrub
    end

    def html_to_text(html)
      return "" if html.to_s.empty?

      # Convert common structural tags to newlines before stripping
      text = html.dup
      text.gsub!(/<\s*br\s*\/?>/i, "\n")
      text.gsub!(/<\/\s*(p|div|li|tr|h[1-6])\s*>/i, "\n\n")
      text.gsub!(/<\s*li[^>]*>/i, "• ")
      text.gsub!(/<[^>]+>/, "")

      # Decode common HTML entities
      {
        "&nbsp;" => " ", "&amp;" => "&", "&lt;" => "<", "&gt;" => ">",
        "&quot;" => "\"", "&#39;" => "'", "&apos;" => "'", "&ndash;" => "–",
        "&mdash;" => "—", "&hellip;" => "…", "&rsquo;" => "’",
        "&lsquo;" => "‘", "&ldquo;" => "“", "&rdquo;" => "”"
      }.each { |entity, char| text.gsub!(entity, char) }
      text.gsub!(/&#(\d+);/) { [Regexp.last_match(1).to_i].pack("U*") }

      text.gsub(/\n{3,}/, "\n\n").strip
    end

    # Remove Gmail/Outlook quoted history so each message shows only its own content.
    def strip_quoted_history(body)
      lines = body.split("\n")

      cut_idx = nil
      lines.each_with_index do |line, idx|
        l = line.strip
        if l.match?(/\AOn\s.+wrote:\s*\z/) ||                                # Gmail: "On Mon, Apr 21, 2026 at 2:43 PM X wrote:"
           l.match?(/\A[-_]{2,}\s*Original Message\s*[-_]{2,}\z/i) ||        # "----- Original Message -----"
           l.match?(/\AYou don't often get email from/i) ||                  # Outlook safety banner
           (l.match?(/\AFrom:\s+.+/) &&                                      # Outlook header block: "From:" followed within a few lines by "Sent:" or "To:"
            lines[(idx + 1)..(idx + 4)]&.any? { |nxt| nxt.strip.match?(/\A(Sent|To|Subject):\s/i) })
          cut_idx = idx
          break
        end
      end

      trimmed = cut_idx ? lines[0...cut_idx] : lines
      trimmed = trimmed.reject { |line| line.lstrip.start_with?(">") }
      trimmed.join("\n").gsub(/\n{3,}/, "\n\n").strip
    end

    def first_header(msg, name)
      headers = msg["payload"]&.dig("headers") || []
      h = headers.find { |x| x["name"].to_s.downcase == name.downcase }
      h && h["value"]
    end
  end
end
