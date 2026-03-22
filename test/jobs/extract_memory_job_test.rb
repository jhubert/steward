require 'test_helper'

class ExtractMemoryJobTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @conversation = conversations(:alice_telegram)
  end

  test 'extracts memory items from unextracted messages' do
    stub_llm_response('[{"category": "fact", "content": "User name is Alice"}]')

    assert_difference 'MemoryItem.count', 1 do
      ExtractMemoryJob.perform_now(@conversation.id)
    end

    item = MemoryItem.last
    assert_equal 'fact', item.category
    assert_equal 'User name is Alice', item.content
    assert_equal users(:alice), item.user
    assert_equal @conversation.agent, item.agent
    assert_equal @conversation, item.conversation
    assert_kind_of Array, item.metadata['source_message_range']
    assert_equal 2, item.metadata['source_message_range'].size
  end

  test 'advances extraction pointer after processing' do
    stub_llm_response('[{"category": "fact", "content": "User name is Alice"}]')

    ExtractMemoryJob.perform_now(@conversation.id)

    state = @conversation.state.reload
    assert_equal messages(:steward_reply).id, state.extracted_through_message_id
  end

  test 'advances pointer even when nothing extracted' do
    stub_llm_response('[]')

    assert_no_difference 'MemoryItem.count' do
      ExtractMemoryJob.perform_now(@conversation.id)
    end

    state = @conversation.state.reload
    assert_equal messages(:steward_reply).id, state.extracted_through_message_id
  end

  test 'skips when no unextracted messages exist' do
    state = @conversation.ensure_state!
    # Use maximum ID since fixture IDs are hash-based, not sequential
    state.advance_extraction!(@conversation.messages.maximum(:id))

    # Should not call the LLM at all
    Rails.configuration.anthropic_client.expects(:messages).never

    ExtractMemoryJob.perform_now(@conversation.id)
  end

  test 'creates nothing when LLM returns malformed JSON' do
    stub_llm_response('not json at all')

    assert_no_difference 'MemoryItem.count' do
      ExtractMemoryJob.perform_now(@conversation.id)
    end

    # Pointer still advances
    state = @conversation.state.reload
    assert_equal messages(:steward_reply).id, state.extracted_through_message_id
  end

  test 'discards job when conversation not found' do
    assert_nothing_raised do
      ExtractMemoryJob.perform_now(0)
    end
  end

  test 'creates multiple memory items from multi-item extraction' do
    json = '[{"category": "fact", "content": "Lives in Toronto"}, {"category": "preference", "content": "Prefers email over Slack"}]'
    stub_llm_response(json)

    assert_difference 'MemoryItem.count', 2 do
      ExtractMemoryJob.perform_now(@conversation.id)
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
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)
  end
end
