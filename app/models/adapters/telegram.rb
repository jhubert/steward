module Adapters
  class Telegram < Base
    API_BASE = 'https://api.telegram.org'.freeze

    def initialize(bot_token:)
      @bot_token = bot_token
    end

    def channel
      'telegram'
    end

    def normalize(raw_params)
      message = raw_params.dig('message') || raw_params.dig('edited_message')
      return nil unless message

      chat = message['chat']
      from = message['from']

      result = {
        user_external_key: 'telegram_chat_id',
        user_external_value: chat['id'].to_s,
        user_name: [from['first_name'], from['last_name']].compact.join(' '),
        external_thread_key: chat['id'].to_s,
        content: message['text'] || message['caption'] || '',
        metadata: {
          telegram_message_id: message['message_id'],
          telegram_chat_type: chat['type']
        }
      }

      # Pass the raw message through so the controller can extract media
      result[:raw_message] = message if has_media?(message)

      result
    end

    def has_media?(message)
      Telegram::MediaDownloader::MEDIA_TYPES.any? { |type| message[type].present? } ||
        message['location'].present? || message['contact'].present? || message['venue'].present?
    end

    def send_typing(conversation)
      chat_id = conversation.external_thread_key

      HTTPX.post(
        "#{API_BASE}/bot#{@bot_token}/sendChatAction",
        json: { chat_id: chat_id, action: 'typing' }
      )
    end

    def send_reply(conversation, message)
      chat_id = conversation.external_thread_key

      # Try Markdown first, fall back to plain text if Telegram can't parse it
      response = HTTPX.post(
        "#{API_BASE}/bot#{@bot_token}/sendMessage",
        json: { chat_id: chat_id, text: message.content, parse_mode: 'Markdown' }
      )

      if response.status != 200
        Rails.logger.warn("[Telegram] Markdown failed, retrying as plain text: #{response.body}")
        response = HTTPX.post(
          "#{API_BASE}/bot#{@bot_token}/sendMessage",
          json: { chat_id: chat_id, text: message.content }
        )
      end

      if response.status != 200
        raise Adapters::DeliveryError, "Telegram sendMessage failed (#{response.status}): #{response.body}"
      end

      response
    end
  end
end
