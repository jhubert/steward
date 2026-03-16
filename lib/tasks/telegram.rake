namespace :telegram do
  desc 'Register Telegram webhook for an agent. Usage: rake telegram:set_webhook[agent_name]'
  task :set_webhook, [:agent_name] => :environment do |_t, args|
    agent = find_agent!(args[:agent_name])
    token = agent.telegram_bot_token
    domain = ENV.fetch("STEWARD_DOMAIN", "steward.boardwise.co")
    url = "https://#{domain}/webhooks/telegram/#{agent.id}"

    response = HTTPX.post(
      "https://api.telegram.org/bot#{token}/setWebhook",
      json: { url: url }
    )

    body = JSON.parse(response.body.to_s)
    if body['ok']
      puts "Webhook set for '#{agent.name}' (id=#{agent.id}): #{url}"
    else
      puts "Failed: #{body['description']}"
    end
  end

  desc 'Remove Telegram webhook for an agent. Usage: rake telegram:delete_webhook[agent_name]'
  task :delete_webhook, [:agent_name] => :environment do |_t, args|
    agent = find_agent!(args[:agent_name])
    token = agent.telegram_bot_token

    response = HTTPX.post("https://api.telegram.org/bot#{token}/deleteWebhook")
    body = JSON.parse(response.body.to_s)
    puts body['ok'] ? "Webhook removed for '#{agent.name}'" : "Failed: #{body['description']}"
  end

  desc 'Show Telegram webhook info for an agent. Usage: rake telegram:webhook_info[agent_name]'
  task :webhook_info, [:agent_name] => :environment do |_t, args|
    agent = find_agent!(args[:agent_name])
    token = agent.telegram_bot_token

    response = HTTPX.get("https://api.telegram.org/bot#{token}/getWebhookInfo")
    body = JSON.parse(response.body.to_s)
    puts JSON.pretty_generate(body)
  end

  desc 'Register webhooks for ALL agents'
  task set_all_webhooks: :environment do
    Agent.unscoped.find_each do |agent|
      next unless agent.telegram_bot_token.present?

      domain = ENV.fetch("STEWARD_DOMAIN", "steward.boardwise.co")
      url = "https://#{domain}/webhooks/telegram/#{agent.id}"
      token = agent.telegram_bot_token

      response = HTTPX.post(
        "https://api.telegram.org/bot#{token}/setWebhook",
        json: { url: url }
      )

      body = JSON.parse(response.body.to_s)
      status = body['ok'] ? 'OK' : "FAILED: #{body['description']}"
      puts "#{agent.name} (id=#{agent.id}): #{status} → #{url}"
    end
  end

  def find_agent!(name)
    abort 'Usage: rake telegram:<task>[agent_name]' unless name.present?
    agent = Agent.unscoped.find_by(name: name)
    abort "Agent '#{name}' not found. Available: #{Agent.unscoped.pluck(:name).join(', ')}" unless agent
    agent
  end
end
