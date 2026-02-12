require 'test_helper'

class Tools::DefinitionBuilderTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
  end

  test 'returns nil for agent with no tools' do
    builder = Tools::DefinitionBuilder.new(agent: agents(:steward))
    assert_nil builder.call
  end

  test 'returns tool definitions for agent with enabled tools' do
    builder = Tools::DefinitionBuilder.new(agent: agents(:jennifer))
    definitions = builder.call

    assert_kind_of Array, definitions
    assert_equal 2, definitions.length

    names = definitions.map { |d| d[:name] }
    assert_includes names, 'find_availability'
    assert_includes names, 'search_contacts'
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
