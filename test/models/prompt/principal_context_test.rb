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
