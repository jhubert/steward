module Admin
  class AgentsController < BaseController
    before_action :set_agent, only: [:show, :edit, :update, :enable_skill, :disable_skill]

    def index
      @agents = Agent.all.order(:name)
    end

    def show
      @principals = @agent.agent_principals.includes(:user)
      @tools = @agent.agent_tools.order(:name)
      @recent_conversations = @agent.conversations.includes(:user).order(updated_at: :desc).limit(20)
    end

    def new
      @agent = Agent.new
    end

    def create
      token_budgets = {}
      (params.dig(:agent, :token_budgets) || {}).each do |key, value|
        token_budgets[key] = value.to_i if value.present?
      end

      settings = {}
      settings["model"] = params.dig(:agent, :model) if params.dig(:agent, :model).present?
      settings["telegram_bot_token"] = params.dig(:agent, :telegram_bot_token) if params.dig(:agent, :telegram_bot_token).present?
      settings["token_budgets"] = token_budgets if token_budgets.any?

      @agent = Agent.new(
        name: params.dig(:agent, :name),
        system_prompt: params.dig(:agent, :system_prompt),
        settings: settings
      )

      if @agent.save
        notice = "Agent created."
        if @agent.settings&.dig("telegram_bot_token").present?
          result = @agent.register_telegram_webhook!
          notice += result[:ok] ? " Webhook registered." : " Webhook failed: #{result[:description]}"
        end
        redirect_to admin_agent_path(@agent), notice: notice
      else
        render :new, status: :unprocessable_entity
      end
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

    def enable_skill
      @agent.enable_skill!(params[:skill_name])
      redirect_to admin_agent_path(@agent), notice: "Skill '#{params[:skill_name]}' enabled."
    rescue ArgumentError => e
      redirect_to admin_agent_path(@agent), alert: e.message
    end

    def disable_skill
      @agent.disable_skill!(params[:skill_name])
      redirect_to admin_agent_path(@agent), notice: "Skill '#{params[:skill_name]}' disabled."
    rescue ArgumentError => e
      redirect_to admin_agent_path(@agent), alert: e.message
    end

    private

    def set_agent
      @agent = Agent.find(params[:id])
    end
  end
end
