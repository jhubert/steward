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
    assert_equal 5, definitions.length

    names = definitions.map { |d| d[:name] }
    assert_includes names, 'find_availability'
    assert_includes names, 'search_contacts'
    assert_includes names, 'save_note'
    assert_includes names, 'read_notes'
    assert_includes names, 'google_setup'
    # Disabled tool should not appear
    assert_not_includes names, 'send_invoice'
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
