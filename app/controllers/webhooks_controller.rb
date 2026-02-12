class WebhooksController < ActionController::API
  # POST /webhooks/telegram
  def telegram
    adapter = Adapters::Telegram.new
    normalized = adapter.normalize(params.to_unsafe_h)

    if normalized.nil? || normalized[:content].blank?
      head :ok
      return
    end

    # Resolve workspace — for Phase 1, use a default workspace.
    # In production, this would be determined by the bot token or routing config.
    workspace = Workspace.find_by(slug: 'default')
    unless workspace
      Rails.logger.error('[Webhook] No default workspace found')
      head :ok
      return
    end

    Current.workspace = workspace

    # Find or create user by Telegram chat ID
    user = User.find_by_external(normalized[:user_external_key], normalized[:user_external_value])
    user ||= User.create!(
      workspace: workspace,
      name: normalized[:user_name],
      external_ids: { normalized[:user_external_key] => normalized[:user_external_value] }
    )

    # Find or create conversation
    agent = workspace.agents.first
    unless agent
      Rails.logger.error("[Webhook] No agent configured for workspace #{workspace.slug}")
      head :ok
      return
    end

    conversation = Conversation.find_or_start(
      user: user,
      agent: agent,
      channel: adapter.channel,
      external_thread_key: normalized[:external_thread_key]
    )

    # Append the incoming message
    message = conversation.messages.create!(
      workspace: workspace,
      user: user,
      role: 'user',
      content: normalized[:content],
      metadata: normalized[:metadata] || {}
    )

    # Enqueue processing
    ProcessMessageJob.perform_later(message.id)

    head :ok
  end
end
