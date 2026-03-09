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

  # --- Fellow agents ---

  test 'fellow_agents returns other agents sharing the same principal' do
    # Alice is principal of both jennifer and markus
    fellows = agents(:jennifer).fellow_agents(users(:alice))
    assert_includes fellows, agents(:markus)
    assert_not_includes fellows, agents(:jennifer)
  end

  test 'fellow_agents returns empty for non-principal user' do
    fellows = agents(:jennifer).fellow_agents(users(:eve))
    assert_empty fellows
  end

  test 'fellow_agents excludes self' do
    fellows = agents(:markus).fellow_agents(users(:alice))
    assert_includes fellows, agents(:jennifer)
    assert_not_includes fellows, agents(:markus)
  end

  test 'fellow_agents returns empty when user has only one agent' do
    # Bob is only a principal of jennifer
    fellows = agents(:jennifer).fellow_agents(users(:bob))
    assert_empty fellows
  end

  # --- Brief description ---

  test 'brief_description extracts first sentence from system_prompt' do
    agent = agents(:markus)
    assert_equal "You are Markus, a financial advisor specializing in corporate finance and tax planning.", agent.brief_description
  end

  test 'brief_description handles missing system_prompt' do
    agent = Agent.new(system_prompt: nil)
    assert_nil agent.brief_description
  end

  test 'brief_description truncates when no sentence ending' do
    agent = Agent.new(system_prompt: "A" * 200)
    assert agent.brief_description.length <= 103 # 100 + "..."
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

  # --- Email handle ---

  test 'email_handle returns value from settings' do
    assert_equal 'jennifer', agents(:jennifer).email_handle
  end

  test 'email_handle returns nil when not configured' do
    assert_nil agents(:steward).email_handle
  end

  test 'find_by_email_handle finds agent by handle' do
    agent = Agent.find_by_email_handle('jennifer')
    assert_equal agents(:jennifer), agent
  end

  test 'find_by_email_handle is case-insensitive' do
    agent = Agent.find_by_email_handle('JENNIFER')
    assert_equal agents(:jennifer), agent
  end

  test 'find_by_email_handle returns nil for unknown handle' do
    assert_nil Agent.find_by_email_handle('unknown')
  end

  test 'find_by_email_handle returns nil for blank handle' do
    assert_nil Agent.find_by_email_handle('')
    assert_nil Agent.find_by_email_handle(nil)
  end

  # --- Skill management ---

  test 'enable_skill! creates agent tools from skill definitions' do
    agent = agents(:steward)
    Skills::Registry.instance.reload!

    assert_difference -> { agent.agent_tools.count }, 3 do
      agent.enable_skill!('pdf')
    end

    tool_names = agent.agent_tools.pluck(:name)
    assert_includes tool_names, 'pdf_extract'
    assert_includes tool_names, 'pdf_coords'
    assert_includes tool_names, 'pdf_fill'
  end

  test 'enable_skill! is idempotent' do
    agent = agents(:steward)
    Skills::Registry.instance.reload!

    agent.enable_skill!('github')

    assert_no_difference -> { agent.agent_tools.count } do
      agent.enable_skill!('github')
    end
  end

  test 'enable_skill! raises on unknown skill' do
    agent = agents(:steward)

    assert_raises(ArgumentError) { agent.enable_skill!('nonexistent') }
  end

  test 'disable_skill! removes agent tools for that skill' do
    agent = agents(:steward)
    Skills::Registry.instance.reload!

    agent.enable_skill!('github')
    assert agent.agent_tools.exists?(name: 'github')

    agent.disable_skill!('github')
    assert_not agent.agent_tools.exists?(name: 'github')
  end

  test 'disable_skill! raises on unknown skill' do
    agent = agents(:steward)

    assert_raises(ArgumentError) { agent.disable_skill!('nonexistent') }
  end

  test 'enabled_skill_names returns skills whose tools all exist' do
    agent = agents(:steward)
    Skills::Registry.instance.reload!

    agent.enable_skill!('github')
    agent.enable_skill!('system')

    names = agent.enabled_skill_names
    assert_includes names, 'github'
    assert_includes names, 'system'
    assert_not_includes names, 'pdf'
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
