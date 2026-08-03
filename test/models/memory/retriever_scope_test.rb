require 'test_helper'

# Covers the retrieval defects found in the Aug 2026 memory audit:
#   - keyword search selected the first five long-ish words, which in a natural
#     question are almost all stopwords
#   - world/research facts competed with principal knowledge for the budget
#   - expired facts stayed recallable forever
class Memory::RetrieverScopeTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @conversation = conversations(:alice_jennifer)
    # Keyword-path only; semantic search needs a live embedding client.
    Rails.configuration.stubs(:openai_client).returns(nil)
    MemoryItem.where(user: users(:alice)).delete_all
  end

  def create_memory(content, **attrs)
    MemoryItem.create!(
      {
        workspace: workspaces(:default),
        user: users(:alice),
        agent: agents(:jennifer),
        conversation: @conversation,
        category: 'fact',
        content: content
      }.merge(attrs)
    )
  end

  def retriever
    Memory::Retriever.new(@conversation, budget: 800)
  end

  # --- keyword term selection ---

  test 'significant_terms drops stopwords and keeps content words' do
    terms = retriever.send(:significant_terms,
                           "What did we decide about the Boardwise launch timeline?")

    assert_includes terms, "boardwise"
    assert_includes terms, "timeline"
    assert_includes terms, "launch"
    refute_includes terms, "did"
    refute_includes terms, "decide"
    refute_includes terms, "about"
    refute_includes terms, "the"
  end

  test 'significant_terms survives a question made entirely of stopwords' do
    assert_empty retriever.send(:significant_terms, "What did you know about that?")
  end

  test 'keyword search matches a natural-language question' do
    create_memory('The Boardwise launch timeline slipped to September')

    result = retriever.call(query: "Can you remind me what we decided about the Boardwise launch timeline?")

    assert_not_nil result, "expected the Boardwise memory to be recalled"
    assert_includes result, "Boardwise launch timeline"
  end

  # --- subject scope ---

  test 'world facts are excluded from prompt context' do
    create_memory('Reddit fell 21% on August 1 2026', subject_scope: 'world')

    assert_nil retriever.call(query: "Reddit August 2026 decline")
  end

  test 'principal facts are included in prompt context' do
    create_memory('Jeremy holds a position in Reddit', subject_scope: 'principal')

    result = retriever.call(query: "Reddit position holdings")
    assert_not_nil result
    assert_includes result, "Jeremy holds a position in Reddit"
  end

  test 'recall tool can opt into world facts' do
    create_memory('Reddit fell 21% on August 1 2026', subject_scope: 'world')

    assert_empty retriever.search(query: "Reddit decline August")
    assert_equal 1, retriever.search(query: "Reddit decline August", include_world: true).size
  end

  # --- expiry ---

  test 'expired memories are not recalled' do
    create_memory('Dentist appointment scheduled for July 3', expires_at: 1.day.ago)

    assert_nil retriever.call(query: "dentist appointment scheduled")
  end

  test 'unexpired memories with a future expiry are recalled' do
    create_memory('Dentist appointment scheduled for September 3', expires_at: 30.days.from_now)

    result = retriever.call(query: "dentist appointment scheduled")
    assert_not_nil result
    assert_includes result, "September 3"
  end

  test 'superseded memories are not recalled' do
    old = create_memory('Jeremy lives in Toronto')
    new_item = create_memory('Jeremy lives in Vancouver')
    old.supersede!(by: new_item)

    result = retriever.call(query: "where does Jeremy live Toronto Vancouver")
    assert_not_nil result
    assert_includes result, "Vancouver"
    refute_includes result, "Toronto"
  end
end
