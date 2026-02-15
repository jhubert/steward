require 'test_helper'

class Adapters::BackgroundTest < ActiveSupport::TestCase
  setup do
    @adapter = Adapters::Background.new
  end

  test 'channel returns background' do
    assert_equal 'background', @adapter.channel
  end

  test 'normalize returns empty hash' do
    assert_equal({}, @adapter.normalize({ 'some' => 'data' }))
  end

  test 'send_reply returns nil' do
    assert_nil @adapter.send_reply(nil, nil)
  end

  test 'send_typing returns nil' do
    assert_nil @adapter.send_typing(nil)
  end
end
