require "test_helper"

class Admin::AgentPrincipalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:default)
    @agent = agents(:steward) # steward has no principals
  end

  test "new renders form" do
    get new_admin_agent_principal_path(@agent)
    assert_response :success
    assert_select "select[name='agent_principal[user_id]']"
  end

  test "create adds principal and redirects" do
    user = users(:alice)
    assert_difference -> { AgentPrincipal.count }, 1 do
      post admin_agent_principals_path(@agent), params: {
        agent_principal: {
          user_id: user.id,
          display_name: "Alice",
          role: "Admin"
        }
      }
    end
    assert_redirected_to admin_agent_path(@agent)
  end

  test "create with duplicate user re-renders form" do
    agent = agents(:jennifer)
    user = users(:alice) # already a principal of jennifer
    assert_no_difference -> { AgentPrincipal.count } do
      post admin_agent_principals_path(agent), params: {
        agent_principal: {
          user_id: user.id,
          display_name: "Alice",
          role: "CEO"
        }
      }
    end
    assert_response :unprocessable_entity
  end

  test "destroy removes principal" do
    agent = agents(:jennifer)
    principal = agent_principals(:jennifer_alice)
    assert_difference -> { AgentPrincipal.count }, -1 do
      delete admin_agent_principal_path(agent, principal)
    end
    assert_redirected_to admin_agent_path(agent)
  end
end
