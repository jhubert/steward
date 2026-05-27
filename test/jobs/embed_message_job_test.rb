require 'test_helper'

class EmbedMessageJobTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @message = messages(:alice_hello)
  end

  test 'saves embedding when OpenAI client available' do
    fake_embedding = Array.new(1536) { rand(-1.0..1.0) }
    mock_client = mock('openai_client')
    mock_client.expects(:embeddings).with(
      parameters: { model: "text-embedding-3-small", input: @message.content }
    ).returns({ "data" => [{ "embedding" => fake_embedding }] })
    Rails.configuration.stubs(:openai_client).returns(mock_client)

    EmbedMessageJob.perform_now(@message.id)

    @message.reload
    assert_not_nil @message.embedding
    assert_not_nil @message.embedded_at
  end

  test 'skips when OpenAI client not configured' do
    Rails.configuration.stubs(:openai_client).returns(nil)
    EmbedMessageJob.perform_now(@message.id)
    assert_nil @message.reload.embedding
  end

  test 'skips system messages' do
    sys = @message.conversation.messages.create!(role: 'system', content: 'session break notice')
    mock_client = mock('openai_client')
    mock_client.expects(:embeddings).never
    Rails.configuration.stubs(:openai_client).returns(mock_client)
    EmbedMessageJob.perform_now(sys.id)
  end

  test 'skips when embedding already present' do
    @message.update_columns(embedding: Array.new(1536, 0.1), embedded_at: Time.current)
    mock_client = mock('openai_client')
    mock_client.expects(:embeddings).never
    Rails.configuration.stubs(:openai_client).returns(mock_client)
    EmbedMessageJob.perform_now(@message.id)
  end

  test 'discards when record not found' do
    assert_nothing_raised { EmbedMessageJob.perform_now(0) }
  end
end
