Rails.application.config.after_initialize do
  key = Rails.application.credentials.dig(:openai, :api_key)

  if key.blank?
    Rails.logger.warn("[OpenAI] API key not found in credentials — embeddings will be disabled")
    Rails.application.config.openai_client = nil
  else
    Rails.application.config.openai_client = OpenAI::Client.new(access_token: key)
  end
end
