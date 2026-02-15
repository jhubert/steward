require 'test_helper'

class ConversationSessionBreakTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @conversation = conversations(:alice_telegram)
    @conversation.ensure_state!
    # Set all existing fixture messages to 10 hours ago so they don't interfere
    @conversation.messages.update_all(created_at: 10.hours.ago)
  end

  test 'session_break_needed? returns false when gap is below threshold' do
    old_msg = @conversation.messages.create!(
      workspace: workspaces(:default), user: users(:alice),
      role: 'assistant', content: 'Previous reply',
      created_at: 2.hours.ago
    )

    new_msg = @conversation.messages.create!(
      workspace: workspaces(:default), user: users(:alice),
      role: 'user', content: 'New message',
      created_at: Time.current
    )

    refute @conversation.session_break_needed?(new_msg)
  end

  test 'session_break_needed? returns true when gap exceeds threshold' do
    old_msg = @conversation.messages.create!(
      workspace: workspaces(:default), user: users(:alice),
      role: 'assistant', content: 'Previous reply',
      created_at: 5.hours.ago
    )

    new_msg = @conversation.messages.create!(
      workspace: workspaces(:default), user: users(:alice),
      role: 'user', content: 'New message',
      created_at: Time.current
    )

    assert @conversation.session_break_needed?(new_msg)
  end

  test 'session_break_needed? respects custom agent session_break_hours' do
    @conversation.agent.update!(settings: { 'session_break_hours' => 10 })

    old_msg = @conversation.messages.create!(
      workspace: workspaces(:default), user: users(:alice),
      role: 'assistant', content: 'Previous reply',
      created_at: 8.hours.ago
    )

    new_msg = @conversation.messages.create!(
      workspace: workspaces(:default), user: users(:alice),
      role: 'user', content: 'New message',
      created_at: Time.current
    )

    refute @conversation.session_break_needed?(new_msg)
  end

  test 'compact_for_session_break! creates summary with gap notice and advances pointer' do
    new_msg = @conversation.messages.create!(
      workspace: workspaces(:default), user: users(:alice),
      role: 'user', content: 'New message',
      created_at: Time.current
    )

    stub_summarizer('Summary of old conversation')

    @conversation.compact_for_session_break!(new_msg)

    state = @conversation.state.reload
    assert_includes state.summary, 'Summary of old conversation'
    assert_includes state.summary, 'Session break'
    assert_match(/hours passed/, state.summary)
    assert state.summarized_through_message_id.present?
  end

  test 'compact_for_session_break! does not create system messages' do
    new_msg = @conversation.messages.create!(
      workspace: workspaces(:default), user: users(:alice),
      role: 'user', content: 'New message',
      created_at: Time.current
    )

    stub_summarizer('Summary')

    assert_no_difference -> { @conversation.messages.count } do
      @conversation.compact_for_session_break!(new_msg)
    end
  end

  test 'compact_for_session_break! is a no-op when no unsummarized messages exist' do
    new_msg = @conversation.messages.create!(
      workspace: workspaces(:default), user: users(:alice),
      role: 'user', content: 'New message',
      created_at: Time.current
    )

    # Mark all existing messages (except the new one) as summarized
    last_old = @conversation.messages.where.not(id: new_msg.id).chronological.last
    @conversation.state.advance_summary!('Old summary', last_old.id) if last_old

    assert_no_difference -> { @conversation.messages.count } do
      @conversation.compact_for_session_break!(new_msg)
    end
  end

  private

  def stub_summarizer(summary_text)
    content_block = Data.define(:type, :text).new(type: :text, text: summary_text)
    usage = Data.define(:input_tokens, :output_tokens).new(input_tokens: 50, output_tokens: 30)
    response = Data.define(:content, :usage, :model, :stop_reason).new(
      content: [content_block], usage: usage, model: 'claude-sonnet-4-5-20250929', stop_reason: :end_turn
    )
    messages_api = stub(create: response)
    Rails.configuration.anthropic_client.stubs(:messages).returns(messages_api)
  end
end
