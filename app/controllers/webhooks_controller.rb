class WebhooksController < ActionController::API
  # POST /webhooks/telegram/:agent_id
  def telegram
    agent = Agent.unscoped.find_by(id: params[:agent_id])
    unless agent
      Rails.logger.error("[Webhook] Unknown agent_id: #{params[:agent_id]}")
      head :ok
      return
    end

    workspace = agent.workspace
    Current.workspace = workspace

    adapter = Adapters::Telegram.new(bot_token: agent.telegram_bot_token)
    normalized = adapter.normalize(params.to_unsafe_h)

    has_media = normalized&.dig(:raw_message).present?

    if normalized.nil? || (normalized[:content].blank? && !has_media)
      head :ok
      return
    end

    # Find or create user by Telegram chat ID
    user = User.find_by_external(normalized[:user_external_key], normalized[:user_external_value])
    user ||= User.create!(
      workspace: workspace,
      name: normalized[:user_name],
      external_ids: { normalized[:user_external_key] => normalized[:user_external_value] }
    )

    # Find or create conversation for this user + agent
    conversation = Conversation.find_or_start(
      user: user,
      agent: agent,
      channel: adapter.channel,
      external_thread_key: normalized[:external_thread_key]
    )

    # Deduplicate: Telegram may re-deliver the same message if the previous
    # webhook response was slow. Skip if we've already stored this message.
    telegram_message_id = normalized.dig(:metadata, "telegram_message_id")
    if telegram_message_id
      already_exists = conversation.messages
                                   .where(role: 'user')
                                   .where("metadata->>'telegram_message_id' = ?", telegram_message_id.to_s)
                                   .exists?
      if already_exists
        head :ok
        return
      end
    end

    # Download media (must happen after conversation exists for storage path)
    attachments = []
    if has_media
      downloader = Adapters::Telegram::MediaDownloader.new(bot_token: agent.telegram_bot_token)
      attachments = downloader.call(
        normalized[:raw_message],
        user_id: user.id
      )
    end

    # Build message content — ensure we always have something
    content = normalized[:content]
    if content.blank? && attachments.any?
      content = attachments.map { |a| a.metadata[:description] || "[#{a.type.capitalize}]" }.join(" ")
    end

    # Build metadata with attachment info
    message_metadata = normalized[:metadata] || {}
    if attachments.any?
      message_metadata["attachments"] = attachments.map { |a| serialize_attachment(a) }
    end

    # Append the incoming message
    message = conversation.messages.create!(
      workspace: workspace,
      user: user,
      role: 'user',
      content: content,
      metadata: message_metadata
    )

    # Enqueue processing
    ProcessMessageJob.perform_later(message.id)

    head :ok
  end

  private

  def serialize_attachment(attachment)
    {
      "type" => attachment.type,
      "file_path" => attachment.file_path,
      "content_type" => attachment.content_type,
      "filename" => attachment.filename,
      "size" => attachment.size
    }.tap do |h|
      h["description"] = attachment.metadata[:description] if attachment.metadata[:description]
    end
  end
end
