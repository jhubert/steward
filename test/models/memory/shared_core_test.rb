require 'test_helper'

# The shared principal core lets every agent serving a person read durable
# identity-level facts about them, instead of each agent re-learning the same
# things. These tests pin the boundaries that sharing must NOT cross.
class Memory::SharedCoreTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    # Keyword path only; semantic search needs a live embedding client.
    Rails.configuration.stubs(:openai_client).returns(nil)
    MemoryItem.unscoped.delete_all

    @alice_jennifer = conversations(:alice_jennifer)
  end

  def memory(content, agent:, user: users(:alice), workspace: workspaces(:default),
             visibility: MemoryItem::AGENT_VISIBILITY, category: 'fact')
    MemoryItem.unscoped.create!(
      workspace: workspace,
      user: user,
      agent: agent,
      category: category,
      content: content,
      visibility: visibility
    )
  end

  def recall(query, conversation: @alice_jennifer)
    Memory::Retriever.new(conversation, budget: 800).call(query: query)
  end

  # --- what the core is for ---

  test 'an agent reads core facts another agent promoted' do
    memory('Jeremy has two daughters, Maya and Nora',
           agent: agents(:steward), visibility: MemoryItem::SHARED_VISIBILITY)

    result = recall('daughters Maya Nora')
    assert_not_nil result, "expected Jennifer to read Steward's core fact about Alice"
    assert_includes result, 'two daughters'
  end

  test 'an agent still reads its own private memories' do
    memory('Jeremy prefers the Q3 deck in landscape', agent: agents(:jennifer))

    result = recall('landscape deck')
    assert_not_nil result
    assert_includes result, 'landscape'
  end

  # --- boundaries sharing must not cross ---

  test 'agent-private memories stay with the agent that formed them' do
    memory('Jeremy vented about a colleague', agent: agents(:steward))

    assert_nil recall('vented colleague'),
               "another agent's private memory must not leak into this agent"
  end

  test 'observations never enter the core even when marked shared' do
    memory('Seemed stressed and short-tempered today',
           agent: agents(:steward),
           category: 'observation',
           visibility: MemoryItem::SHARED_VISIBILITY)

    assert_nil recall('stressed short-tempered'),
               "observations are private to the agent that formed them"
  end

  test 'the core does not cross principals' do
    memory('Bob is allergic to shellfish',
           agent: agents(:steward), user: users(:bob),
           visibility: MemoryItem::SHARED_VISIBILITY)

    assert_nil recall('allergic shellfish'),
               "Alice's agent must not read a core fact about Bob"
  end

  test 'the core does not cross workspaces' do
    memory('Confidential other-tenant detail',
           agent: agents(:steward), user: users(:alice), workspace: workspaces(:other),
           visibility: MemoryItem::SHARED_VISIBILITY)

    assert_nil recall('confidential tenant detail'),
               "sharing must never cross the workspace boundary"
  end

  # --- scope-level guarantees ---

  test 'readable_by_agent returns own memories plus non-private core' do
    own = memory('Own working note', agent: agents(:jennifer))
    core = memory('Core identity fact', agent: agents(:steward),
                  visibility: MemoryItem::SHARED_VISIBILITY)
    other_private = memory('Other agent private note', agent: agents(:steward))
    shared_observation = memory('Tone signal', agent: agents(:steward),
                                category: 'observation',
                                visibility: MemoryItem::SHARED_VISIBILITY)

    ids = MemoryItem.current
                    .where(user: users(:alice))
                    .readable_by_agent(agents(:jennifer))
                    .pluck(:id)

    assert_includes ids, own.id
    assert_includes ids, core.id
    refute_includes ids, other_private.id
    refute_includes ids, shared_observation.id
  end

  test 'memories default to agent-private' do
    item = memory('Something learned', agent: agents(:jennifer))
    assert_equal MemoryItem::AGENT_VISIBILITY, item.visibility
    refute item.shared?
  end

  test 'visibility rejects unknown values' do
    item = MemoryItem.new(
      workspace: workspaces(:default), user: users(:alice), agent: agents(:jennifer),
      category: 'fact', content: 'x', visibility: 'everyone'
    )
    refute item.valid?
    assert_includes item.errors[:visibility], 'is not included in the list'
  end
end
