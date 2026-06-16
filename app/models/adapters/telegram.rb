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
      # Inline-keyboard taps arrive as callback_query updates, not messages.
      # Returning :callback_query lets the controller route them separately.
      if (cb = raw_params['callback_query'])
        return {
          kind: :callback_query,
          callback_query_id: cb['id'],
          callback_data: cb['data'],
          chat_id: cb.dig('message', 'chat', 'id')&.to_s,
          message_id: cb.dig('message', 'message_id'),
          from_telegram_id: cb.dig('from', 'id')&.to_s,
          from_name: [cb.dig('from', 'first_name'), cb.dig('from', 'last_name')].compact.join(' ')
        }
      end

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

    MAX_MESSAGE_LENGTH = 4096

    def send_reply(conversation, message)
      chat_id = conversation.external_thread_key

      chunks = split_message(message.content)
      response = nil

      chunks.each do |chunk|
        response = send_text(chat_id, chunk)
      end

      response
    end

    # Send a message with an inline keyboard. `buttons` is an array of rows;
    # each row is an array of { text:, callback_data: } hashes. Returns the
    # parsed Telegram response (so the caller can record the message_id).
    def send_text_with_keyboard(chat_id, text, buttons)
      keyboard = { inline_keyboard: buttons }
      response = HTTPX.post(
        "#{API_BASE}/bot#{@bot_token}/sendMessage",
        json: { chat_id: chat_id, text: text, parse_mode: 'Markdown', reply_markup: keyboard }
      )

      if response.status != 200
        Rails.logger.warn("[Telegram] keyboard Markdown failed, retrying as plain text: #{response.body}")
        response = HTTPX.post(
          "#{API_BASE}/bot#{@bot_token}/sendMessage",
          json: { chat_id: chat_id, text: text, reply_markup: keyboard }
        )
      end

      if response.status != 200
        raise Adapters::DeliveryError, "Telegram sendMessage failed (#{response.status}): #{response.body}"
      end

      JSON.parse(response.body.to_s) rescue {}
    end

    # Acknowledge a callback query so the spinner on the user's tap clears.
    def answer_callback_query(callback_query_id, text: nil)
      payload = { callback_query_id: callback_query_id }
      payload[:text] = text if text
      HTTPX.post("#{API_BASE}/bot#{@bot_token}/answerCallbackQuery", json: payload)
    end

    # Strip the inline keyboard off a previously-sent approval message —
    # used after the action is resolved so the buttons can't be tapped again.
    def edit_message_text(chat_id, message_id, new_text)
      HTTPX.post(
        "#{API_BASE}/bot#{@bot_token}/editMessageText",
        json: { chat_id: chat_id, message_id: message_id, text: new_text, parse_mode: 'Markdown' }
      )
    end

    def send_text(chat_id, text)
      # Try Markdown first, fall back to plain text if Telegram can't parse it
      response = HTTPX.post(
        "#{API_BASE}/bot#{@bot_token}/sendMessage",
        json: { chat_id: chat_id, text: text, parse_mode: 'Markdown' }
      )

      if response.status != 200
        Rails.logger.warn("[Telegram] Markdown failed, retrying as plain text: #{response.body}")
        response = HTTPX.post(
          "#{API_BASE}/bot#{@bot_token}/sendMessage",
          json: { chat_id: chat_id, text: text }
        )
      end

      if response.status != 200
        raise Adapters::DeliveryError, "Telegram sendMessage failed (#{response.status}): #{response.body}"
      end

      response
    end

    private

    def split_message(text)
      return [text] if text.length <= MAX_MESSAGE_LENGTH

      chunks = []
      remaining = text

      while remaining.length > MAX_MESSAGE_LENGTH
        # Find a good split point: prefer double newline, then single newline, then space
        split_at = remaining.rindex("\n\n", MAX_MESSAGE_LENGTH) ||
                   remaining.rindex("\n", MAX_MESSAGE_LENGTH) ||
                   remaining.rindex(" ", MAX_MESSAGE_LENGTH) ||
                   MAX_MESSAGE_LENGTH

        chunks << remaining[0...split_at]
        remaining = remaining[split_at..].lstrip
      end

      chunks << remaining unless remaining.empty?
      chunks
    end
  end
end
