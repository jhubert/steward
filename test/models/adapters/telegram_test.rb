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

  test 'normalize uses caption when text is absent' do
    raw = {
      'message' => {
        'message_id' => 50,
        'from' => { 'first_name' => 'Alice' },
        'chat' => { 'id' => 111_111, 'type' => 'private' },
        'caption' => 'Check this out',
        'photo' => [{ 'file_id' => 'abc', 'file_unique_id' => 'x', 'width' => 800, 'height' => 600 }]
      }
    }

    result = @adapter.normalize(raw)
    assert_equal 'Check this out', result[:content]
  end

  test 'normalize includes raw_message when media is present' do
    raw = {
      'message' => {
        'message_id' => 51,
        'from' => { 'first_name' => 'Alice' },
        'chat' => { 'id' => 111_111, 'type' => 'private' },
        'photo' => [{ 'file_id' => 'abc', 'file_unique_id' => 'x', 'width' => 800, 'height' => 600 }]
      }
    }

    result = @adapter.normalize(raw)
    assert result[:raw_message].present?
    assert result[:raw_message]['photo'].present?
  end

  test 'normalize omits raw_message for text-only messages' do
    raw = {
      'message' => {
        'message_id' => 52,
        'from' => { 'first_name' => 'Alice' },
        'chat' => { 'id' => 111_111, 'type' => 'private' },
        'text' => 'Just text'
      }
    }

    result = @adapter.normalize(raw)
    assert_nil result[:raw_message]
  end

  test 'normalize includes raw_message for location' do
    raw = {
      'message' => {
        'message_id' => 53,
        'from' => { 'first_name' => 'Alice' },
        'chat' => { 'id' => 111_111, 'type' => 'private' },
        'location' => { 'latitude' => 48.85, 'longitude' => 2.35 }
      }
    }

    result = @adapter.normalize(raw)
    assert result[:raw_message].present?
    assert result[:raw_message]['location'].present?
  end
end
