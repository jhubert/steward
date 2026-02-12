Rails.application.config.after_initialize do
  key = Rails.application.credentials.dig(:anthropic, :api_key)
  raise "Anthropic API key not found in credentials" if key.blank?

  Rails.application.config.anthropic_client = Anthropic::Client.new(api_key: key)
end
