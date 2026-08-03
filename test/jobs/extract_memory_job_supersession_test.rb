require 'test_helper'

# Supersession machinery existed on MemoryItem but nothing ever called it —
# 0 of 4,828 production memories were superseded. These tests pin the wiring.
class ExtractMemoryJobSupersessionTest < ActiveSupport::TestCase
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

  def existing_memory(content, user: users(:alice), agent: nil)
    MemoryItem.create!(
      workspace: workspaces(:default),
      user: user,
      agent: agent || @conversation.agent,
      conversation: @conversation,
      category: 'fact',
      content: content
    )
  end

  test 'retires the memory the extractor says was replaced' do
    old = existing_memory('Jeremy lives in Toronto')

    stub_llm_response(
      %([{"category": "fact", "content": "Jeremy lives in Vancouver", "supersedes": #{old.id}}])
    )

    ExtractMemoryJob.perform_now(@conversation.id)

    old.reload
    assert_not_nil old.superseded_at, "expected the old fact to be retired"
    assert_equal 'Jeremy lives in Vancouver', old.superseded_by.content
    refute_includes MemoryItem.current.pluck(:content), 'Jeremy lives in Toronto'
  end

  test 'ignores a supersedes id that was never shown to the extractor' do
    other_user_memory = existing_memory('Bob lives in Calgary', user: users(:bob))

    stub_llm_response(
      %([{"category": "fact", "content": "Jeremy lives in Vancouver", "supersedes": #{other_user_memory.id}}])
    )

    ExtractMemoryJob.perform_now(@conversation.id)

    assert_nil other_user_memory.reload.superseded_at,
               "another principal's memory must never be retired from this conversation"
  end

  test 'ignores a hallucinated supersedes id' do
    stub_llm_response(
      '[{"category": "fact", "content": "Jeremy lives in Vancouver", "supersedes": 99999999}]'
    )

    assert_difference 'MemoryItem.count', 1 do
      ExtractMemoryJob.perform_now(@conversation.id)
    end
  end

  test 'stores subject scope and expiry from the extractor' do
    stub_llm_response(<<~JSON)
      [
        {"category": "fact", "content": "Jeremy prefers morning meetings",
         "scope": "principal", "durability": "durable"},
        {"category": "fact", "content": "WTI oil reached $86.80 on August 1",
         "scope": "world", "durability": "transient"}
      ]
    JSON

    ExtractMemoryJob.perform_now(@conversation.id)

    principal = MemoryItem.find_by(content: 'Jeremy prefers morning meetings')
    world = MemoryItem.find_by(content: 'WTI oil reached $86.80 on August 1')

    assert_equal 'principal', principal.subject_scope
    assert_nil principal.expires_at, "durable facts should not expire"

    assert_equal 'world', world.subject_scope
    assert_not_nil world.expires_at, "transient facts should carry an expiry"
    assert_in_delta MemoryItem::TRANSIENT_TTL.from_now, world.expires_at, 60
  end

  test 'defaults to principal scope and no expiry when extractor omits them' do
    stub_llm_response('[{"category": "fact", "content": "Jeremy has two children"}]')

    ExtractMemoryJob.perform_now(@conversation.id)

    item = MemoryItem.find_by(content: 'Jeremy has two children')
    assert_equal 'principal', item.subject_scope
    assert_nil item.expires_at
  end
end
