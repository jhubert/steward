require 'test_helper'

class GenerateEmbeddingJobTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @memory_item = memory_items(:alice_preference)
  end

  test 'saves embedding when OpenAI client available' do
    fake_embedding = Array.new(1536) { rand(-1.0..1.0) }
    mock_client = mock('openai_client')
    mock_client.expects(:embeddings).with(
      parameters: { model: "text-embedding-3-small", input: "[preference] #{@memory_item.content}" }
    ).returns({ "data" => [{ "embedding" => fake_embedding }] })
    Rails.configuration.stubs(:openai_client).returns(mock_client)

    GenerateEmbeddingJob.perform_now(@memory_item.id)

    @memory_item.reload
    assert_not_nil @memory_item.embedding
  end

  test 'skips when OpenAI client not configured' do
    Rails.configuration.stubs(:openai_client).returns(nil)

    assert_nothing_raised do
      GenerateEmbeddingJob.perform_now(@memory_item.id)
    end

    @memory_item.reload
    assert_nil @memory_item.embedding
  end

  test 'discards when record not found' do
    assert_nothing_raised do
      GenerateEmbeddingJob.perform_now(0)
    end
  end

  test 'skips when embedding already present' do
    fake_embedding = Array.new(1536) { 0.1 }
    @memory_item.update!(embedding: fake_embedding)

    mock_client = mock('openai_client')
    mock_client.expects(:embeddings).never
    Rails.configuration.stubs(:openai_client).returns(mock_client)

    GenerateEmbeddingJob.perform_now(@memory_item.id)
  end
end
