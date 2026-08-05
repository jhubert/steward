Rails.application.config.after_initialize do
  key = ENV["ANTHROPIC_API_KEY"] || Rails.application.credentials.dig(:anthropic, :api_key)

  if key.blank?
    if Rails.env.test?
      # Build a real client object with a placeholder key rather than nil.
      # Tests stub `.messages` on this object, and Mocha cannot stub nil
      # ("can't stub method on frozen object: nil"), so a nil client fails
      # every LLM-touching test on any machine without credentials — which is
      # exactly what CI is. No request is ever made: each of those tests
      # replaces the messages API before the job runs.
      Rails.logger.warn("[Anthropic] No API key — using placeholder client in test")
      Rails.application.config.anthropic_client = Anthropic::Client.new(
        api_key: "test-placeholder-key",
        timeout: 120.0
      )
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
