ANTHROPIC_CLIENT = Anthropic::Client.new(
  api_key: Rails.application.credentials.dig(:anthropic, :api_key)
)
