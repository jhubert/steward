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

  test 'extraction_model returns default when not configured' do
    assert_equal 'claude-haiku-4-5-20251001', agents(:steward).extraction_model
  end

  test 'extraction_model returns configured value' do
    agent = agents(:steward)
    agent.update!(settings: { 'extraction_model' => 'claude-sonnet-4-5-20250929' })
    assert_equal 'claude-sonnet-4-5-20250929', agent.extraction_model
  end

  test 'token_budgets returns defaults' do
    budgets = agents(:steward).token_budgets
    assert_equal 800, budgets['agent_core']
    assert_equal 4000, budgets['history']
  end

  test 'token_budgets includes principal_context default' do
    budgets = agents(:steward).token_budgets
    assert_equal 1200, budgets['principal_context']
  end

  test 'principal_mode? returns false when no principals' do
    assert_not agents(:steward).principal_mode?
  end

  test 'principal_mode? returns true when principals exist' do
    assert agents(:jennifer).principal_mode?
  end

  test 'principal? checks user membership' do
    assert agents(:jennifer).principal?(users(:alice))
    assert agents(:jennifer).principal?(users(:bob))
    assert_not agents(:steward).principal?(users(:alice))
  end

  test 'principal_record returns the join record' do
    record = agents(:jennifer).principal_record(users(:alice))
    assert_equal 'CEO', record.role
  end

  test 'fellow_principals excludes current user' do
    fellows = agents(:jennifer).fellow_principals(users(:alice))
    assert_equal 1, fellows.count
    assert_equal users(:bob), fellows.first.user
  end
end
