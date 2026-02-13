require "test_helper"

class Admin::AgentToolsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:default)
    @agent = agents(:jennifer)
    @tool = agent_tools(:jennifer_scheduling)
  end

  test "edit renders form" do
    get edit_admin_agent_tool_path(@agent, @tool)
    assert_response :success
    assert_select "textarea[name='agent_tool[description]']"
    assert_select "input[name='agent_tool[command_template]']"
  end

  test "update with valid params redirects to agent show" do
    patch admin_agent_tool_path(@agent, @tool), params: {
      agent_tool: {
        description: "Updated description",
        command_template: "python3 updated.py {attendees}",
        working_directory: "/srv/steward/skills/scheduling",
        timeout_seconds: "45",
        input_schema: '{"type":"object","properties":{"attendees":{"type":"string"}},"required":["attendees"]}',
        enabled: "1"
      }
    }
    assert_redirected_to admin_agent_path(@agent)

    @tool.reload
    assert_equal "Updated description", @tool.description
    assert_equal "python3 updated.py {attendees}", @tool.command_template
    assert_equal 45, @tool.timeout_seconds
  end

  test "update with invalid JSON re-renders edit" do
    patch admin_agent_tool_path(@agent, @tool), params: {
      agent_tool: {
        description: "desc",
        command_template: "cmd",
        timeout_seconds: "30",
        input_schema: "not valid json{",
        enabled: "1"
      }
    }
    assert_response :unprocessable_entity
  end

  test "toggle flips enabled status" do
    assert @tool.enabled?
    patch toggle_admin_agent_tool_path(@agent, @tool)
    assert_redirected_to admin_agent_path(@agent)
    assert_not @tool.reload.enabled?

    patch toggle_admin_agent_tool_path(@agent, @tool)
    assert @tool.reload.enabled?
  end
end
