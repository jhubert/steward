module Admin
  class AgentsController < BaseController
    before_action :set_agent, only: [:show, :edit, :update]

    def index
      @agents = Agent.all.order(:name)
    end

    def show
      @principals = @agent.agent_principals.includes(:user)
      @tools = @agent.agent_tools.order(:name)
      @recent_conversations = @agent.conversations.includes(:user).order(updated_at: :desc).limit(20)
    end

    def edit
    end

    def update
      token_budgets = {}
      (params.dig(:agent, :token_budgets) || {}).each do |key, value|
        token_budgets[key] = value.to_i if value.present?
      end

      settings = @agent.settings || {}
      settings["model"] = params.dig(:agent, :model) if params.dig(:agent, :model).present?
      settings["telegram_bot_token"] = params.dig(:agent, :telegram_bot_token) if params.dig(:agent, :telegram_bot_token).present?
      settings["token_budgets"] = token_budgets if token_budgets.any?

      if @agent.update(name: params.dig(:agent, :name), system_prompt: params.dig(:agent, :system_prompt), settings: settings)
        redirect_to admin_agent_path(@agent), notice: "Agent updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def set_agent
      @agent = Agent.find(params[:id])
    end
  end
end
