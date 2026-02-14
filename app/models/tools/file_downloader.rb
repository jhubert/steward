require "resolv"

module Tools
  class FileDownloader
    Result = Data.define(:success, :path, :error, :size)

    MAX_FILE_SIZE = 50 * 1024 * 1024 # 50 MB

    BLOCKED_IP_RANGES = [
      IPAddr.new("10.0.0.0/8"),
      IPAddr.new("172.16.0.0/12"),
      IPAddr.new("192.168.0.0/16"),
      IPAddr.new("127.0.0.0/8"),
      IPAddr.new("169.254.0.0/16"),
      IPAddr.new("0.0.0.0/8"),
      IPAddr.new("::1/128"),
      IPAddr.new("fc00::/7"),
      IPAddr.new("fe80::/10")
    ].freeze

    def initialize(agent_id:, conversation_id:)
      @agent_id = agent_id
      @conversation_id = conversation_id
    end

    def call(url, filename: nil)
      uri = validate_url(url)
      return uri unless uri.is_a?(URI::HTTP)

      check_ssrf(uri)

      response = HTTPX.get(uri.to_s)

      unless response.status == 200
        return Result.new(success: false, path: nil, error: "HTTP #{response.status}", size: nil)
      end

      body = response.body.to_s
      if body.bytesize > MAX_FILE_SIZE
        return Result.new(success: false, path: nil, error: "File too large (#{body.bytesize} bytes, max #{MAX_FILE_SIZE})", size: nil)
      end

      safe_name = sanitize_filename(filename || filename_from_uri(uri))
      dir = storage_dir
      FileUtils.mkdir_p(dir)
      path = File.join(dir, safe_name)

      File.binwrite(path, body)
      Result.new(success: true, path: path, error: nil, size: body.bytesize)
    rescue => e
      Result.new(success: false, path: nil, error: e.message, size: nil)
    end

    private

    def validate_url(url)
      uri = URI.parse(url.to_s)
      unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
        return Result.new(success: false, path: nil, error: "Only http/https URLs are supported", size: nil)
      end
      uri
    rescue URI::InvalidURIError => e
      Result.new(success: false, path: nil, error: "Invalid URL: #{e.message}", size: nil)
    end

    def check_ssrf(uri)
      addresses = Resolv.getaddresses(uri.host)
      raise "Could not resolve hostname: #{uri.host}" if addresses.empty?

      addresses.each do |addr_str|
        addr = IPAddr.new(addr_str)
        if BLOCKED_IP_RANGES.any? { |range| range.include?(addr) }
          raise "Blocked: #{uri.host} resolves to private/internal address #{addr_str}"
        end
      end
    end

    def sanitize_filename(name)
      safe = File.basename(name.to_s)
      safe = safe.gsub(/[^a-zA-Z0-9._\-]/, "_")
      safe = "download" if safe.blank? || safe.start_with?(".")
      safe = safe[0, 255]
      safe
    end

    def filename_from_uri(uri)
      path = uri.path.to_s.chomp("/")
      name = File.basename(path) if path.present?
      name.presence || "download"
    end

    def storage_dir
      Rails.root.join("data", "downloads", @agent_id.to_s, @conversation_id.to_s).to_s
    end
  end
end
