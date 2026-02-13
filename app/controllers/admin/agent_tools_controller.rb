module Admin
  class AgentToolsController < BaseController
    before_action :set_agent
    before_action :set_tool, only: [:edit, :update, :toggle]

    def edit
    end

    def update
      attrs = {
        description: params.dig(:agent_tool, :description),
        command_template: params.dig(:agent_tool, :command_template),
        working_directory: params.dig(:agent_tool, :working_directory),
        timeout_seconds: params.dig(:agent_tool, :timeout_seconds),
        enabled: params.dig(:agent_tool, :enabled) == "1"
      }

      schema_json = params.dig(:agent_tool, :input_schema)
      if schema_json.present?
        begin
          attrs[:input_schema] = JSON.parse(schema_json)
        rescue JSON::ParserError => e
          @agent_tool.errors.add(:input_schema, "is not valid JSON: #{e.message}")
          return render :edit, status: :unprocessable_entity
        end
      end

      if @agent_tool.update(attrs)
        redirect_to admin_agent_path(@agent), notice: "Tool '#{@agent_tool.name}' updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def toggle
      @agent_tool.update!(enabled: !@agent_tool.enabled?)
      status = @agent_tool.enabled? ? "enabled" : "disabled"
      redirect_to admin_agent_path(@agent), notice: "Tool '#{@agent_tool.name}' #{status}."
    end

    private

    def set_agent
      @agent = Agent.find(params[:agent_id])
    end

    def set_tool
      @agent_tool = @agent.agent_tools.find(params[:id])
    end
  end
end
