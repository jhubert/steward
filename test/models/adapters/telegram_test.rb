require 'test_helper'

class Adapters::TelegramTest < ActiveSupport::TestCase
  setup do
    @adapter = Adapters::Telegram.new(bot_token: 'test-token')
  end

  test 'channel returns telegram' do
    assert_equal 'telegram', @adapter.channel
  end

  test 'normalize extracts message data' do
    raw = {
      'message' => {
        'message_id' => 42,
        'from' => { 'first_name' => 'Alice', 'last_name' => 'Smith' },
        'chat' => { 'id' => 111_111, 'type' => 'private' },
        'text' => 'Hello!'
      }
    }

    result = @adapter.normalize(raw)

    assert_equal 'telegram_chat_id', result[:user_external_key]
    assert_equal '111111', result[:user_external_value]
    assert_equal 'Alice Smith', result[:user_name]
    assert_equal '111111', result[:external_thread_key]
    assert_equal 'Hello!', result[:content]
    assert_equal 42, result[:metadata][:telegram_message_id]
  end

  test 'normalize returns nil for non-message updates' do
    raw = { 'update_id' => 12_345 }
    assert_nil @adapter.normalize(raw)
  end

  test 'normalize handles missing last name' do
    raw = {
      'message' => {
        'message_id' => 1,
        'from' => { 'first_name' => 'Alice' },
        'chat' => { 'id' => 111_111, 'type' => 'private' },
        'text' => 'Hi'
      }
    }

    result = @adapter.normalize(raw)
    assert_equal 'Alice', result[:user_name]
  end
end
