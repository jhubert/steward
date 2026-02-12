require 'test_helper'

class ExtractMemoryJobTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @conversation = conversations(:alice_telegram)
    @user_message = messages(:alice_hello)
    @assistant_message = messages(:steward_reply)
  end

  test 'creates memory items from extracted facts' do
    stub_llm_response('[{"category": "fact", "content": "User name is Alice"}]')

    assert_difference 'MemoryItem.count', 1 do
      ExtractMemoryJob.perform_now(@conversation.id, @user_message.id, @assistant_message.id)
    end

    item = MemoryItem.last
    assert_equal 'fact', item.category
    assert_equal 'User name is Alice', item.content
    assert_equal users(:alice), item.user
    assert_equal @conversation, item.conversation
    assert_equal @user_message.id, item.metadata['source_user_message_id']
    assert_equal @assistant_message.id, item.metadata['source_assistant_message_id']
  end

  test 'creates nothing when extraction returns empty array' do
    stub_llm_response('[]')

    assert_no_difference 'MemoryItem.count' do
      ExtractMemoryJob.perform_now(@conversation.id, @user_message.id, @assistant_message.id)
    end
  end

  test 'creates nothing when LLM returns malformed JSON' do
    stub_llm_response('not json at all')

    assert_no_difference 'MemoryItem.count' do
      ExtractMemoryJob.perform_now(@conversation.id, @user_message.id, @assistant_message.id)
    end
  end

  test 'discards job when conversation not found' do
    assert_nothing_raised do
      ExtractMemoryJob.perform_now(0, @user_message.id, @assistant_message.id)
    end
  end

  test 'creates multiple memory items from multi-item extraction' do
    json = '[{"category": "fact", "content": "Lives in Toronto"}, {"category": "preference", "content": "Prefers email over Slack"}]'
    stub_llm_response(json)

    assert_difference 'MemoryItem.count', 2 do
      ExtractMemoryJob.perform_now(@conversation.id, @user_message.id, @assistant_message.id)
    end
  end

  private

  def stub_llm_response(text)
    content_block = Data.define(:text).new(text: text)
    usage = Data.define(:output_tokens).new(output_tokens: 50)
    response = Data.define(:content, :usage, :model).new(
      content: [content_block], usage: usage, model: 'claude-haiku-4-5-20251001'
    )

    messages_api = stub(create: response)
    ANTHROPIC_CLIENT.stubs(:messages).returns(messages_api)
  end
end
