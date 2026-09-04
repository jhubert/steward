require "open3"

module Basecamp
  # Connects a Basecamp OAuth identity to an agent, mirroring the shape of
  # Gog::Authenticator (configured? / provision! / start_auth / complete_auth)
  # so the basecamp_setup tool reads like google_setup.
  #
  # Identity is per agent, not per principal: an agent posts to Basecamp as
  # itself, and every write is attributed to that account. Each agent gets its
  # own config directory so one agent cannot read another's credentials.
  class Authenticator
    DATA_ROOT = Rails.root.join("data", "basecamp")
    BRIDGE = Rails.root.join("skills", "basecamp", "scripts", "auth_bridge.rb")
    BIN_CANDIDATES = [
      ENV["BASECAMP_BIN"],
      "/usr/local/bin/basecamp",
      File.join(Dir.home, ".local", "bin", "basecamp")
    ].compact.freeze

    # How long start_auth waits for the CLI to print its authorization URL.
    URL_TIMEOUT = 20
    # How long complete_auth waits for the bridge to finish the exchange.
    COMPLETE_TIMEOUT = 45

    Result = Data.define(:success, :output, :error)

    def initialize(agent:)
      @agent = agent
    end

    def config_home
      DATA_ROOT.join(@agent.id.to_s).to_s
    end

    # True once the CLI reports an authenticated account in this agent's dir.
    def configured?
      return false unless File.directory?(config_home)

      stdout, _stderr, status = run_cli("auth", "status", "--json")
      return false unless status&.success?

      payload = JSON.parse(stdout)
      payload.dig("data", "authenticated") == true
    rescue JSON::ParserError
      false
    end

    def provision!
      FileUtils.mkdir_p(config_home)
      config_home
    end

    # Spawns the detached bridge and returns the authorization URL to hand to
    # the user. The bridge stays alive waiting for complete_auth.
    def start_auth
      bin = resolve_bin
      return Result.new(success: false, output: nil, error: "The basecamp CLI was not found on this server.") unless bin

      provision!
      return Result.new(success: false, output: nil, error: "A setup attempt is already in progress. Wait for it to finish or expire before starting another.") if in_progress?

      log_path = File.join(config_home, "auth.log")
      FileUtils.rm_f(log_path)

      pid = Process.spawn(
        { "BASECAMP_NONINTERACTIVE" => "1" },
        RbConfig.ruby, BRIDGE.to_s, config_home, bin,
        out: File::NULL, err: File::NULL, pgroup: true
      )
      Process.detach(pid)
      File.write(File.join(config_home, "auth.pid"), pid.to_s)

      url = wait_for_url(log_path)
      if url
        Result.new(success: true, output: url, error: nil)
      else
        stop_pending!
        Result.new(success: false, output: nil, error: "Timed out waiting for Basecamp to return an authorization URL.")
      end
    end

    # Hands the pasted callback URL to the waiting bridge and reports the
    # outcome once the token exchange finishes.
    def complete_auth(callback_url)
      url = callback_url.to_s.strip
      return Result.new(success: false, output: nil, error: "A callback URL is required.") if url.empty?
      unless url.start_with?("http://", "https://")
        return Result.new(success: false, output: nil, error: "That does not look like a callback URL. Paste the full address from the browser, starting with http://.")
      end
      unless in_progress?
        return Result.new(success: false, output: nil, error: "No setup is in progress. Run the 'start' action first — authorization URLs expire.")
      end

      status_path = File.join(config_home, "auth.status")
      FileUtils.rm_f(status_path)
      File.write(File.join(config_home, "auth.callback"), url)

      deadline = Time.current + COMPLETE_TIMEOUT
      while Time.current < deadline
        if File.exist?(status_path)
          state, detail = File.read(status_path).split("\n", 2)
          return Result.new(success: true, output: detail.to_s.strip, error: nil) if state == "ok"
          return Result.new(success: false, output: nil, error: detail.to_s.strip.presence || "Authentication failed.")
        end
        sleep 0.5
      end

      Result.new(success: false, output: nil, error: "Timed out waiting for Basecamp to complete authentication.")
    end

    # Env injected into the agent's basecamp tool at call time.
    def tool_credentials
      creds = { "BASECAMP_CONFIG_HOME" => config_home }
      account = resolve_account_id
      creds["BASECAMP_ACCOUNT_ID"] = account if account
      creds
    end

    # Almost every command needs an account ("--account is required (or set
    # account_id in config)"), and OAuth alone does not establish one. Resolve
    # it right after login so the tool works without anyone editing config by
    # hand — the agent cannot, since `config` and `--account` are both blocked.
    #
    # Returns nil when the choice is not ours to make: no accounts, or more
    # than one, where guessing could post to the wrong company's Basecamp.
    def resolve_account_id
      stdout, _stderr, status = run_cli("accounts", "list", "--json")
      return nil unless status&.success?

      accounts = JSON.parse(stdout).dig("data")
      return nil unless accounts.is_a?(Array) && accounts.size == 1

      accounts.first["id"]&.to_s
    rescue JSON::ParserError
      nil
    end

    # Names the accounts this identity can reach, for error messages when the
    # account cannot be resolved automatically.
    def available_accounts
      stdout, _stderr, status = run_cli("accounts", "list", "--json")
      return [] unless status&.success?

      Array(JSON.parse(stdout).dig("data")).map { |a| "#{a['name']} (#{a['id']})" }
    rescue JSON::ParserError
      []
    end

    private

    def in_progress?
      pid_file = File.join(config_home, "auth.pid")
      return false unless File.exist?(pid_file)

      pid = File.read(pid_file).to_i
      return false if pid <= 0

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def stop_pending!
      pid_file = File.join(config_home, "auth.pid")
      return unless File.exist?(pid_file)

      pid = File.read(pid_file).to_i
      Process.kill("TERM", pid) if pid > 0
    rescue Errno::ESRCH, Errno::EPERM
      nil
    ensure
      FileUtils.rm_f(pid_file)
    end

    # The CLI prints the bare endpoint first ("Authenticating via launchpad
    # (https://launchpad.37signals.com/authorization/new)") and the real
    # authorization URL several lines later. Matching the first URL yields a
    # link with no client_id or state, which fails silently for the user — so
    # require the query parameters that make it authorizable.
    def wait_for_url(log_path)
      deadline = Time.current + URL_TIMEOUT
      while Time.current < deadline
        url = extract_auth_url(log_path)
        return url if url

        sleep 0.5
      end
      nil
    end

    def extract_auth_url(log_path)
      return nil unless File.exist?(log_path)

      text = File.read(log_path)
      # The bridge streams output as it arrives, so only whole lines are safe
      # to scan — a partial line could yield a truncated URL.
      last_newline = text.rindex("\n")
      return nil unless last_newline

      complete = text[0, last_newline + 1]
      url = complete.scan(%r{https://\S*launchpad\.37signals\.com/\S+})
                    .find { |u| u.include?("client_id=") && u.include?("state=") }
      return nil unless url

      strip_legacy_type(url.sub(/[).,]+\z/, ""))
    end

    # The CLI sends the legacy 37signals `type=web_server` alongside the
    # standard `response_type=code` (internal/auth/auth.go). Launchpad now
    # rejects it with "Unsupported authorization type. Use response_type=code."
    # even though response_type is already correct, so the link fails the
    # moment a human signs in. The parameter is redundant — response_type
    # names the flow — and dropping it only affects the authorize request we
    # hand to the user. The callback, state check, and code exchange all
    # happen inside the CLI and are untouched.
    def strip_legacy_type(url)
      uri = URI.parse(url)
      params = URI.decode_www_form(uri.query.to_s).reject { |k, v| k == "type" && v == "web_server" }
      uri.query = params.empty? ? nil : URI.encode_www_form(params)
      uri.to_s
    rescue URI::InvalidURIError
      url
    end

    def resolve_bin
      BIN_CANDIDATES.find { |p| File.executable?(p) }
    end

    def run_cli(*args)
      bin = resolve_bin
      return [nil, nil, nil] unless bin

      Open3.capture3(
        { "XDG_CONFIG_HOME" => config_home, "BASECAMP_NONINTERACTIVE" => "1" },
        bin, *args
      )
    rescue Errno::ENOENT
      [nil, nil, nil]
    end
  end
end
