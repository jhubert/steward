namespace :telegram do
  desc 'Register the Telegram webhook URL'
  task :set_webhook, [:url] => :environment do |_t, args|
    url = args[:url]
    abort 'Usage: rake telegram:set_webhook[https://your-domain.com/webhooks/telegram]' unless url

    token = Rails.application.credentials.dig(:telegram, :bot_token)
    abort 'No telegram bot_token in credentials' unless token

    response = HTTPX.post(
      "https://api.telegram.org/bot#{token}/setWebhook",
      json: { url: url }
    )

    body = JSON.parse(response.body.to_s)
    if body['ok']
      puts "Webhook set to: #{url}"
    else
      puts "Failed: #{body['description']}"
    end
  end

  desc 'Remove the Telegram webhook'
  task delete_webhook: :environment do
    token = Rails.application.credentials.dig(:telegram, :bot_token)
    response = HTTPX.post("https://api.telegram.org/bot#{token}/deleteWebhook")
    body = JSON.parse(response.body.to_s)
    puts body['ok'] ? 'Webhook removed' : "Failed: #{body['description']}"
  end

  desc 'Show current Telegram webhook info'
  task webhook_info: :environment do
    token = Rails.application.credentials.dig(:telegram, :bot_token)
    response = HTTPX.get("https://api.telegram.org/bot#{token}/getWebhookInfo")
    body = JSON.parse(response.body.to_s)
    puts JSON.pretty_generate(body)
  end
end
