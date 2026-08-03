require 'test_helper'

class ExtractMemoryJobCoreTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @conversation = conversations(:alice_telegram)
  end

  def stub_llm_response(text)
    content_block = Data.define(:text).new(text: text)
    usage = Data.define(:output_tokens).new(output_tokens: 50)
    response = Data.define(:content, :usage, :model).new(
      content: [content_block], usage: usage, model: 'claude-haiku-4-5-20251001'
    )

    messages_api = stub(create: response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)
  end

  test 'promotes a core fact into the shared principal core' do
    stub_llm_response('[{"category": "fact", "content": "Jeremy has two daughters", "core": true}]')

    ExtractMemoryJob.perform_now(@conversation.id)

    item = MemoryItem.find_by(content: 'Jeremy has two daughters')
    assert_equal MemoryItem::SHARED_VISIBILITY, item.visibility
    assert item.shared?
  end

  test 'keeps non-core facts private to the extracting agent' do
    stub_llm_response('[{"category": "fact", "content": "Jeremy wants the deck in landscape"}]')

    ExtractMemoryJob.perform_now(@conversation.id)

    item = MemoryItem.find_by(content: 'Jeremy wants the deck in landscape')
    assert_equal MemoryItem::AGENT_VISIBILITY, item.visibility
  end

  test 'refuses to share an observation even when the model marks it core' do
    stub_llm_response('[{"category": "observation", "content": "Seemed anxious about the move", "core": true}]')

    ExtractMemoryJob.perform_now(@conversation.id)

    item = MemoryItem.find_by(content: 'Seemed anxious about the move')
    assert_equal MemoryItem::AGENT_VISIBILITY, item.visibility,
                 "observations must never be promoted into the shared core"
  end

  test 'dedup context includes core facts promoted by other agents' do
    MemoryItem.create!(
      workspace: workspaces(:default),
      user: @conversation.user,
      agent: agents(:jennifer),
      category: 'fact',
      content: 'Jeremy has two daughters',
      visibility: MemoryItem::SHARED_VISIBILITY
    )

    context = ExtractMemoryJob.new.send(:dedup_context, @conversation)

    assert_includes context.pluck(:content), 'Jeremy has two daughters',
                    "an agent should see the core so it does not re-extract it"
  end

  test 'dedup context excludes another agent private memories' do
    MemoryItem.create!(
      workspace: workspaces(:default),
      user: @conversation.user,
      agent: agents(:jennifer),
      category: 'fact',
      content: 'Jennifer-only working detail'
    )

    context = ExtractMemoryJob.new.send(:dedup_context, @conversation)

    refute_includes context.pluck(:content), 'Jennifer-only working detail'
  end
end
