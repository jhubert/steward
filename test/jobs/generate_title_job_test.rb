require 'test_helper'

class GenerateTitleJobTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @conversation = conversations(:alice_telegram)
    @conversation.update_column(:title, nil)
  end

  test 'generates title from conversation messages' do
    stub_llm_response("Getting Started with Steward")

    GenerateTitleJob.perform_now(@conversation.id)

    @conversation.reload
    assert_equal "Getting Started with Steward", @conversation.title
  end

  test 'skips when title already present' do
    @conversation.update_column(:title, "Existing Title")

    # Should not call the API
    GenerateTitleJob.perform_now(@conversation.id)

    @conversation.reload
    assert_equal "Existing Title", @conversation.title
  end

  test 'discards when conversation not found' do
    assert_nothing_raised do
      GenerateTitleJob.perform_now(0)
    end
  end

  test 'handles empty conversation gracefully' do
    @conversation.messages.delete_all

    # Should not call the API at all
    GenerateTitleJob.perform_now(@conversation.id)

    @conversation.reload
    assert_nil @conversation.title
  end

  private

  def stub_llm_response(text)
    content_block = Data.define(:text).new(text: text)
    usage = Data.define(:output_tokens).new(output_tokens: 10)
    response = Data.define(:content, :usage, :model).new(
      content: [content_block], usage: usage, model: 'claude-haiku-4-5-20251001'
    )

    messages_api = stub(create: response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)
  end
end
