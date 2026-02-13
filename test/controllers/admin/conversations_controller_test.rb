require "test_helper"

class Admin::ConversationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:default)
    @conversation = conversations(:alice_telegram)
  end

  test "index lists conversations" do
    get admin_conversations_path
    assert_response :success
    assert_select "table tbody tr"
  end

  test "index filters by agent" do
    agent = agents(:jennifer)
    get admin_conversations_path(agent_id: agent.id)
    assert_response :success
    # Jennifer has alice_jennifer and bob_jennifer, not alice_telegram
    assert_select "td", { text: "Steward", count: 0 }
  end

  test "show displays conversation with messages" do
    get admin_conversation_path(@conversation)
    assert_response :success
    assert_select ".message", minimum: 1
    assert_select ".message-content", "Hello, Steward!"
  end
end
