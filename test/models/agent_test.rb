require 'test_helper'

class AgentTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
  end

  test 'model returns default when not configured' do
    assert_equal 'claude-sonnet-4-5-20250929', agents(:steward).model
  end

  test 'model returns configured value' do
    agent = agents(:steward)
    agent.update!(settings: { 'model' => 'claude-opus-4-6' })
    assert_equal 'claude-opus-4-6', agent.model
  end

  test 'token_budgets returns defaults' do
    budgets = agents(:steward).token_budgets
    assert_equal 800, budgets['agent_core']
    assert_equal 4000, budgets['history']
  end
end
