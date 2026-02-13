require "open3"

module Gog
  class Authenticator
    CLIENT_SECRET_PATH = Rails.root.join("data", "gog", "client_secret.json")
    GOG_DATA_ROOT = Rails.root.join("data", "gog")

    Result = Data.define(:success, :output, :error)

    def initialize(agent_principal:)
      @principal = agent_principal
      @user = agent_principal.user
    end

    def configured?
      @principal.credentials.key?("gog_keyring_password")
    end

    def provision!
      user_dir = user_data_dir
      FileUtils.mkdir_p(File.join(user_dir, "gog"))

      unless configured?
        password = SecureRandom.hex(32)
        creds = @principal.credentials.merge("gog_keyring_password" => password)
        @principal.update!(credentials: creds)
      end

      # Install client credentials into user's config dir
      target = File.join(user_dir, "gog", "client_secret.json")
      unless File.exist?(target)
        FileUtils.cp(CLIENT_SECRET_PATH, target)
      end
    end

    def start_auth(email)
      provision!

      argv = [
        "gog", "auth", "add", email,
        "--services", "user",
        "--remote",
        "--step", "1"
      ]

      stdout, stderr, status = execute(argv)

      if status.exitstatus == 0
        auth_url = extract_url(stdout + stderr)
        if auth_url
          Result.new(success: true, output: auth_url, error: nil)
        else
          Result.new(success: false, output: stdout, error: "Could not extract auth URL from output")
        end
      else
        Result.new(success: false, output: stdout, error: stderr)
      end
    end

    def complete_auth(email, auth_url)
      argv = [
        "gog", "auth", "add", email,
        "--services", "user",
        "--remote",
        "--step", "2",
        "--auth-url", auth_url
      ]

      stdout, stderr, status = execute(argv)

      if status.exitstatus == 0
        Result.new(success: true, output: stdout, error: nil)
      else
        Result.new(success: false, output: stdout, error: stderr)
      end
    end

    private

    def user_data_dir
      GOG_DATA_ROOT.join(@user.id.to_s).to_s
    end

    def gog_env
      {
        "XDG_CONFIG_HOME" => user_data_dir,
        "GOG_KEYRING_PASSWORD" => @principal.credentials["gog_keyring_password"],
        "GOG_KEYRING_BACKEND" => "file"
      }
    end

    def execute(argv)
      Open3.capture3(gog_env, *argv, chdir: GOG_DATA_ROOT.to_s)
    end

    def extract_url(text)
      text[/https?:\/\/\S+/]
    end
  end
end
