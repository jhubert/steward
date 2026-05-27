require 'test_helper'

class Prompt::PrincipalContextTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
  end

  test 'returns nil for non-principal agent' do
    conversation = conversations(:alice_telegram)
    result = Prompt::PrincipalContext.new(conversation).call
    assert_nil result
  end

  test 'returns nil when user is not a principal of non-principal-mode agent' do
    conversation = Conversation.create!(
      workspace: workspaces(:default),
      user: users(:bob),
      agent: agents(:steward),
      channel: 'telegram',
      external_thread_key: '999999'
    )
    result = Prompt::PrincipalContext.new(conversation).call
    assert_nil result
  end

  test 'returns external user context for non-principal of principal-mode agent' do
    # Create a non-principal user talking to Jennifer (a principal-mode agent)
    outsider = User.create!(workspace: workspaces(:default), name: "Bryan Alvis", external_ids: { "telegram_chat_id" => "777777" })
    conversation = Conversation.create!(
      workspace: workspaces(:default),
      user: outsider,
      agent: agents(:jennifer),
      channel: 'telegram',
      external_thread_key: '777777'
    )
    result = Prompt::PrincipalContext.new(conversation).call

    assert_includes result, "Bryan Alvis"
    assert_includes result, "NOT one of your principals"
    assert_includes result, "External User Guidelines"
    assert_includes result, "Do not share private information"
    assert_not_includes result, "Your Principals"
    assert_not_includes result, "Discretion Guidelines"
    assert_not_includes result, "Cross-Principal Context"
  end

  test 'includes current speaker identification' do
    conversation = conversations(:alice_jennifer)
    result = Prompt::PrincipalContext.new(conversation).call

    assert_includes result, 'You are currently speaking with Alice (CEO)'
  end

  test 'includes principal roster' do
    conversation = conversations(:alice_jennifer)
    result = Prompt::PrincipalContext.new(conversation).call

    assert_includes result, 'Your Principals'
    assert_includes result, 'Alice (CEO)'
    assert_includes result, 'Bob (COO)'
  end

  test 'marks current speaker in roster' do
    conversation = conversations(:alice_jennifer)
    result = Prompt::PrincipalContext.new(conversation).call

    assert_includes result, 'Alice (CEO) ← current'
  end

  test 'includes contact details in roster' do
    conversation = conversations(:alice_jennifer)
    result = Prompt::PrincipalContext.new(conversation).call

    assert_includes result, 'Email: alice@example.com, Phone: +1-555-0001'
    assert_includes result, 'Email: bob@example.com'
  end

  test 'includes fellow agents roster for principal with fellow agents' do
    conversation = conversations(:alice_jennifer)
    result = Prompt::PrincipalContext.new(conversation).call

    assert_includes result, 'Fellow Agents'
    assert_includes result, 'Markus'
    assert_includes result, 'financial advisor'
    assert_includes result, 'consult_agent'
  end

  test 'omits fellow agents roster when no fellow agents exist' do
    conversation = conversations(:bob_jennifer)
    result = Prompt::PrincipalContext.new(conversation).call

    assert_not_includes result, 'Fellow Agents'
  end

  test 'includes discretion guidelines' do
    conversation = conversations(:alice_jennifer)
    result = Prompt::PrincipalContext.new(conversation).call

    assert_includes result, 'Discretion Guidelines'
  end

  test 'includes cross-principal memory items' do
    conversation = conversations(:alice_jennifer)
    result = Prompt::PrincipalContext.new(conversation).call

    assert_includes result, 'Cross-Principal Context'
    assert_includes result, 'Bob manages the operations team'
    assert_includes result, 'Bob committed to delivering the Q2 report by Friday'
  end

  test 'cross-principal memories carry always-on provenance label' do
    conversation = conversations(:alice_jennifer)
    result = Prompt::PrincipalContext.new(conversation).call

    cross_principal_section = result.split('## Cross-Principal Context').last
    # Every line in the cross-principal section must tag its source so the
    # current speaker's agent doesn't quote Bob's facts back to Alice unattributed.
    cross_principal_section.lines.grep(/^- /).each do |line|
      assert_match(/\[from /, line, "missing [from <name>] label: #{line.inspect}")
    end
  end

  test 'cross-principal memories include a date marker on each item' do
    conversation = conversations(:alice_jennifer)
    result = Prompt::PrincipalContext.new(conversation).call

    cross_principal_section = result.split('## Cross-Principal Context').last
    cross_principal_section.lines.grep(/^- /).each do |line|
      assert_match(/\((today|\d+d ago|\d+w ago|\d{4}-\d{2}-\d{2})\)/, line,
                   "missing date suffix: #{line.inspect}")
    end
  end

  test 'observation-category memories are excluded from cross-principal section' do
    MemoryItem.create!(
      workspace: workspaces(:default),
      user: users(:bob),
      agent: agents(:jennifer),
      conversation: conversations(:bob_jennifer),
      category: 'observation',
      content: 'BOB_PRIVATE_OBSERVATION about emotional state'
    )

    conversation = conversations(:alice_jennifer)
    result = Prompt::PrincipalContext.new(conversation).call

    cross_principal_section = result.split('## Cross-Principal Context').last
    assert_not_includes cross_principal_section, 'BOB_PRIVATE_OBSERVATION'
  end

  test 'cross-principal surfacing writes a MemoryAccessLog entry per fellow' do
    conversation = conversations(:alice_jennifer)

    assert_difference 'MemoryAccessLog.count', 1 do
      Prompt::PrincipalContext.new(conversation).call
    end

    log = MemoryAccessLog.order(:created_at).last
    assert_equal 'principal_context', log.context
    assert_equal users(:alice).id, log.viewing_user_id
    assert_equal users(:bob).id, log.subject_user_id
  end

  test 'excludes current user own memories from cross-principal section' do
    conversation = conversations(:alice_jennifer)
    result = Prompt::PrincipalContext.new(conversation).call

    # The cross-principal section should NOT contain Alice's own memories
    cross_principal_section = result.split('## Cross-Principal Context').last
    assert_not_includes cross_principal_section, 'Alice prefers morning meetings'
    assert_not_includes cross_principal_section, 'Alice is based in Toronto'
  end

  test 'omits cross-principal section when fellows have no memories' do
    # Delete Bob's memory items
    MemoryItem.where(user: users(:bob)).destroy_all

    conversation = conversations(:alice_jennifer)
    result = Prompt::PrincipalContext.new(conversation).call

    assert_not_includes result, 'Cross-Principal Context'
  end

  test 'respects token budget by limiting memory items' do
    # Create many memory items for Bob to test budget limiting
    30.times do |i|
      MemoryItem.create!(
        workspace: workspaces(:default),
        user: users(:bob),
        agent: agents(:jennifer),
        conversation: conversations(:bob_jennifer),
        category: 'fact',
        content: "Detailed fact number #{i} about Bob's work responsibilities and commitments that takes up significant space in the prompt"
      )
    end

    conversation = conversations(:alice_jennifer)
    # Use a very small budget to force truncation
    result = Prompt::PrincipalContext.new(conversation, budget: 100).call

    # Should still have the section but with limited items
    if result.include?('Cross-Principal Context')
      bob_facts = result.scan(/\[fact\]/).count
      assert bob_facts < 32, "Should have limited memory items due to budget"
    end
  end
end
