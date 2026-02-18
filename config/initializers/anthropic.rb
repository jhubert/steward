Rails.application.config.after_initialize do
  key = ENV["ANTHROPIC_API_KEY"] || Rails.application.credentials.dig(:anthropic, :api_key)

  if key.blank?
    if Rails.env.test?
      Rails.logger.warn("[Anthropic] No API key — using nil client in test")
      Rails.application.config.anthropic_client = nil
    else
      raise "Anthropic API key not found. Set ANTHROPIC_API_KEY env var or add to credentials."
    end
  else
    Rails.application.config.anthropic_client = Anthropic::Client.new(
      api_key: key,
      timeout: 120.0 # seconds — default is 600s which causes lock cascades
    )
  end
end
