require 'test_helper'

class Tools::DefinitionBuilderTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
  end

  test 'returns builtin tools for agent with no agent-specific tools' do
    builder = Tools::DefinitionBuilder.new(agent: agents(:steward))
    definitions = builder.call

    assert_kind_of Array, definitions
    names = definitions.map { |d| d[:name] }
    assert_includes names, 'save_note'
    assert_includes names, 'read_notes'
  end

  test 'returns agent tools plus builtin tools for agent with enabled tools' do
    builder = Tools::DefinitionBuilder.new(agent: agents(:jennifer))
    definitions = builder.call

    assert_kind_of Array, definitions
    assert_equal 11, definitions.length

    names = definitions.map { |d| d[:name] }
    assert_includes names, 'find_availability'
    assert_includes names, 'search_contacts'
    assert_includes names, 'github'
    assert_includes names, 'save_note'
    assert_includes names, 'read_notes'
    assert_includes names, 'remember'
    assert_includes names, 'google_setup'
    assert_includes names, 'download_file'
    assert_includes names, 'schedule_task'
    assert_includes names, 'list_scheduled_tasks'
    assert_includes names, 'cancel_scheduled_task'
    # Disabled tool should not appear
    assert_not_includes names, 'send_invoice'
  end

  test 'does not include send_message for normal conversations' do
    conversation = conversations(:alice_telegram)
    builder = Tools::DefinitionBuilder.new(agent: agents(:steward), conversation: conversation)
    definitions = builder.call

    names = definitions.map { |d| d[:name] }
    assert_not_includes names, 'send_message'
  end

  test 'does not include send_message when no conversation given' do
    builder = Tools::DefinitionBuilder.new(agent: agents(:jennifer))
    definitions = builder.call

    names = definitions.map { |d| d[:name] }
    assert_not_includes names, 'send_message'
  end

  test 'includes send_message for background conversations' do
    bg_conversation = Conversation.find_or_start(
      user: users(:alice),
      agent: agents(:jennifer),
      channel: "background",
      external_thread_key: "background:test"
    )
    builder = Tools::DefinitionBuilder.new(agent: agents(:jennifer), conversation: bg_conversation)
    definitions = builder.call

    names = definitions.map { |d| d[:name] }
    assert_includes names, 'send_message'
  end

  test 'each definition has required Anthropic fields' do
    builder = Tools::DefinitionBuilder.new(agent: agents(:jennifer))
    definitions = builder.call

    definitions.each do |defn|
      assert defn.key?(:name), 'definition must include name'
      assert defn.key?(:description), 'definition must include description'
      assert defn.key?(:input_schema), 'definition must include input_schema'
    end
  end
end
