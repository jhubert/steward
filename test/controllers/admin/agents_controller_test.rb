require "test_helper"

class Admin::AgentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:default)
    @agent = agents(:jennifer)
  end

  test "index lists all agents" do
    get admin_agents_path
    assert_response :success
    assert_select "td a", "Jennifer"
    assert_select "td a", "Steward"
  end

  test "show displays agent details" do
    get admin_agent_path(@agent)
    assert_response :success
    assert_select "h1", "Jennifer"
    assert_select "h2", /Principals/
    assert_select "h2", /Tools/
  end

  test "edit renders form" do
    get edit_admin_agent_path(@agent)
    assert_response :success
    assert_select "input[name='agent[name]'][value='Jennifer']"
    assert_select "textarea[name='agent[system_prompt]']"
  end

  test "update with valid params redirects to show" do
    patch admin_agent_path(@agent), params: {
      agent: {
        name: "Jennifer Updated",
        system_prompt: "Updated prompt.",
        model: "claude-haiku-4-5-20251001",
        token_budgets: { agent_core: "1000", history: "5000" }
      }
    }
    assert_redirected_to admin_agent_path(@agent)

    @agent.reload
    assert_equal "Jennifer Updated", @agent.name
    assert_equal "Updated prompt.", @agent.system_prompt
    assert_equal "claude-haiku-4-5-20251001", @agent.settings["model"]
    assert_equal 1000, @agent.settings.dig("token_budgets", "agent_core")
    assert_equal 5000, @agent.settings.dig("token_budgets", "history")
  end

  test "update with invalid params re-renders edit" do
    patch admin_agent_path(@agent), params: {
      agent: { name: "", system_prompt: "" }
    }
    assert_response :unprocessable_entity
  end
end
