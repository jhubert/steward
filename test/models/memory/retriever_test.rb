require 'test_helper'

class Memory::RetrieverTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @conversation = conversations(:alice_telegram)
  end

  test 'returns nil when no memory items exist for user' do
    MemoryItem.where(user: users(:alice)).delete_all

    result = Memory::Retriever.new(@conversation, budget: 800).call(query: "test query")
    assert_nil result
  end

  test 'keyword search finds matching items' do
    MemoryItem.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      conversation: @conversation,
      category: 'fact',
      content: 'Alice works at Acme Corp'
    )

    # Disable semantic search (no OpenAI client)
    Rails.configuration.stubs(:openai_client).returns(nil)

    result = Memory::Retriever.new(@conversation, budget: 800).call(query: "Acme Corp work")
    assert_not_nil result
    assert_includes result, "Long-Term Memory"
    assert_includes result, "Alice works at Acme Corp"
  end

  test 'enforces user isolation — does not return other users items' do
    Rails.configuration.stubs(:openai_client).returns(nil)

    result = Memory::Retriever.new(@conversation, budget: 800).call(query: "operations team")
    # bob_fact fixture says "Bob manages the operations team" — should NOT appear for alice
    assert_nil result
  end

  test 'respects budget truncation' do
    5.times do |i|
      MemoryItem.create!(
        workspace: workspaces(:default),
        user: users(:alice),
        conversation: @conversation,
        category: 'fact',
        content: "Fact number #{i} with some extra padding text to fill budget"
      )
    end

    Rails.configuration.stubs(:openai_client).returns(nil)

    # Very small budget: only ~1 item should fit
    result = Memory::Retriever.new(@conversation, budget: 20).call(query: "Fact number")
    assert_not_nil result
    lines = result.split("\n").select { |l| l.start_with?("- ") }
    assert lines.size < 5
  end

  test 'graceful degradation when OpenAI client unavailable' do
    Rails.configuration.stubs(:openai_client).returns(nil)

    # Should still work via keyword fallback
    result = Memory::Retriever.new(@conversation, budget: 800).call(query: "morning meetings")
    # alice_preference fixture: "Alice prefers morning meetings before 10am"
    assert_not_nil result
    assert_includes result, "morning meetings"
  end

  test 'graceful degradation when OpenAI raises error' do
    mock_client = mock('openai_client')
    mock_client.stubs(:embeddings).raises(Faraday::ConnectionFailed.new("connection failed"))
    Rails.configuration.stubs(:openai_client).returns(mock_client)

    # Should still work via keyword fallback
    result = Memory::Retriever.new(@conversation, budget: 800).call(query: "morning meetings")
    assert_not_nil result
    assert_includes result, "morning meetings"
  end

  test 'cross-thread retrieval finds items from other conversations' do
    # Create a memory item from alice's jennifer conversation
    MemoryItem.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      conversation: conversations(:alice_jennifer),
      category: 'decision',
      content: 'Alice decided to use React for the frontend'
    )

    Rails.configuration.stubs(:openai_client).returns(nil)

    # Searching from alice_telegram should find items from alice_jennifer
    result = Memory::Retriever.new(@conversation, budget: 800).call(query: "React frontend")
    assert_not_nil result
    assert_includes result, "React for the frontend"
  end
end
