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

  test 'trigger creates background conversation and message and enqueues job' do
    agent = agents(:jennifer)
    user = users(:alice)

    message = nil
    assert_difference 'Conversation.count', 1 do
      assert_difference 'Message.count', 1 do
        message = agent.trigger(user: user, content: 'New email from bob@example.com')
      end
    end

    assert_equal 'user', message.role
    assert_equal 'New email from bob@example.com', message.content
    assert_equal 'trigger', message.metadata['source']

    conversation = message.conversation
    assert_equal 'background', conversation.channel
    assert_equal "background:#{agent.id}:#{user.id}", conversation.external_thread_key
    assert_equal agent, conversation.agent
    assert_equal user, conversation.user
  end

  test 'principal_env_for returns empty hash when no credentials' do
    agent = agents(:jennifer)
    env = agent.principal_env_for(users(:alice))
    assert_equal({}, env)
  end

  test 'principal_env_for returns GOG env when credentials present' do
    principal = agent_principals(:jennifer_alice)
    principal.update!(credentials: { "gog_keyring_password" => "test-pass-123" })

    agent = agents(:jennifer)
    env = agent.principal_env_for(users(:alice))

    assert_equal "file", env["GOG_KEYRING_BACKEND"]
    assert_equal "test-pass-123", env["GOG_KEYRING_PASSWORD"]
    assert_match %r{data/gog/#{users(:alice).id}}, env["XDG_CONFIG_HOME"]
  end

  test 'principal_env_for returns empty hash for non-principal' do
    agent = agents(:steward)
    env = agent.principal_env_for(users(:alice))
    assert_equal({}, env)
  end

  test 'trigger reuses existing background conversation' do
    agent = agents(:jennifer)
    user = users(:alice)

    agent.trigger(user: user, content: 'First event')

    assert_no_difference 'Conversation.count' do
      agent.trigger(user: user, content: 'Second event')
    end
  end
end
