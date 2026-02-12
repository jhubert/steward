module Adapters
  class Telegram < Base
    API_BASE = 'https://api.telegram.org'.freeze

    def channel
      'telegram'
    end

    def normalize(raw_params)
      message = raw_params.dig('message') || raw_params.dig('edited_message')
      return nil unless message

      chat = message['chat']
      from = message['from']

      {
        user_external_key: 'telegram_chat_id',
        user_external_value: chat['id'].to_s,
        user_name: [from['first_name'], from['last_name']].compact.join(' '),
        external_thread_key: chat['id'].to_s,
        content: message['text'] || '',
        metadata: {
          telegram_message_id: message['message_id'],
          telegram_chat_type: chat['type']
        }
      }
    end

    def send_typing(conversation)
      chat_id = conversation.external_thread_key
      token = Rails.application.credentials.dig(:telegram, :bot_token)

      HTTPX.post(
        "#{API_BASE}/bot#{token}/sendChatAction",
        json: { chat_id: chat_id, action: 'typing' }
      )
    end

    def send_reply(conversation, message)
      chat_id = conversation.external_thread_key
      token = Rails.application.credentials.dig(:telegram, :bot_token)

      response = HTTPX.post(
        "#{API_BASE}/bot#{token}/sendMessage",
        json: {
          chat_id: chat_id,
          text: message.content,
          parse_mode: 'Markdown'
        }
      )

      Rails.logger.error("[Telegram] Failed to send message: #{response.body}") unless response.status == 200

      response
    end
  end
end
