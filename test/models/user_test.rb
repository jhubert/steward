require 'test_helper'

class UserTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
  end

  test 'find_by_external finds user by telegram chat id' do
    user = User.find_by_external('telegram_chat_id', '111111')
    assert_equal users(:alice), user
  end

  test 'find_by_external returns nil for unknown id' do
    user = User.find_by_external('telegram_chat_id', '999999')
    assert_nil user
  end

  test 'workspace scoping isolates users' do
    as_workspace(:default)
    default_users = User.all.to_a

    as_workspace(:other)
    other_users = User.all.to_a

    assert_includes default_users, users(:alice)
    assert_not_includes default_users, users(:eve)
    assert_includes other_users, users(:eve)
    assert_not_includes other_users, users(:alice)
  end

  # --- User.merge! tests ---

  test 'merge! combines external_ids from duplicates into primary' do
    primary = User.create!(workspace: workspaces(:default), name: "Primary", external_ids: { "telegram_chat_id" => "100", "emails" => ["a@example.com"] })
    dup1 = User.create!(workspace: workspaces(:default), name: "Dup1", external_ids: { "telegram_chat_id" => "200", "emails" => ["b@example.com"] })
    dup2 = User.create!(workspace: workspaces(:default), name: "Dup2", external_ids: { "emails" => ["c@example.com", "a@example.com"] })

    User.merge!(primary, dup1, dup2)

    primary.reload
    assert_equal "100", primary.external_ids["telegram_chat_id"]
    assert_includes primary.external_ids["emails"], "a@example.com"
    assert_includes primary.external_ids["emails"], "b@example.com"
    assert_includes primary.external_ids["emails"], "c@example.com"
    # Deduplicated
    assert_equal 3, primary.external_ids["emails"].size

    # Duplicates are deleted
    assert_nil User.unscoped.find_by(id: dup1.id)
    assert_nil User.unscoped.find_by(id: dup2.id)
  end

  test 'merge! reassigns conversations and messages to primary' do
    primary = User.create!(workspace: workspaces(:default), name: "Primary", external_ids: {})
    dup = User.create!(workspace: workspaces(:default), name: "Dup", external_ids: {})

    conv = Conversation.create!(workspace: workspaces(:default), user: dup, agent: agents(:steward), channel: "email", external_thread_key: "merge-conv-test")
    msg = Message.create!(workspace: workspaces(:default), user: dup, conversation: conv, role: "user", content: "Hello")

    User.merge!(primary, dup)

    conv.reload
    msg.reload
    assert_equal primary.id, conv.user_id
    assert_equal primary.id, msg.user_id
    assert_nil User.unscoped.find_by(id: dup.id)
  end

  test 'merge! handles conversation unique constraint conflicts' do
    primary = User.create!(workspace: workspaces(:default), name: "Primary", external_ids: { "telegram_chat_id" => "900" })
    dup = User.create!(workspace: workspaces(:default), name: "Dup", external_ids: { "telegram_chat_id" => "901" })

    # Both users have a telegram conversation with the same agent and thread key
    conv1 = Conversation.create!(workspace: workspaces(:default), user: primary, agent: agents(:steward), channel: "telegram", external_thread_key: "shared-key")
    msg1 = Message.create!(workspace: workspaces(:default), user: primary, conversation: conv1, role: "user", content: "From primary")

    conv2 = Conversation.create!(workspace: workspaces(:default), user: dup, agent: agents(:steward), channel: "telegram", external_thread_key: "shared-key")
    msg2 = Message.create!(workspace: workspaces(:default), user: dup, conversation: conv2, role: "user", content: "From dup")

    User.merge!(primary, dup)

    # Dup's conversation should be deleted, its messages moved to primary's conversation
    assert_nil Conversation.unscoped.find_by(id: conv2.id)
    msg2.reload
    assert_equal conv1.id, msg2.conversation_id
    assert_equal primary.id, msg2.user_id
  end

  test 'merge! handles agent_principal unique constraint conflicts' do
    primary = User.create!(workspace: workspaces(:default), name: "Primary", external_ids: {})
    dup = User.create!(workspace: workspaces(:default), name: "Dup", external_ids: {})

    # Both have an agent_principal for the same agent
    ap_primary = AgentPrincipal.create!(workspace: workspaces(:default), agent: agents(:steward), user: primary, role: "CEO", display_name: "Primary")
    ap_dup = AgentPrincipal.create!(workspace: workspaces(:default), agent: agents(:steward), user: dup, role: "CTO", display_name: "Dup")

    User.merge!(primary, dup)

    # Primary's agent_principal should remain, dup's should be deleted
    assert AgentPrincipal.unscoped.exists?(id: ap_primary.id)
    assert_nil AgentPrincipal.unscoped.find_by(id: ap_dup.id)
  end

  test 'merge! raises on empty duplicates list' do
    primary = users(:alice)
    assert_raises(ArgumentError) { User.merge!(primary) }
  end
end
