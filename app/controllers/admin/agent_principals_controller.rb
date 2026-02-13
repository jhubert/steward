module Admin
  class AgentPrincipalsController < BaseController
    before_action :set_agent

    def new
      @agent_principal = @agent.agent_principals.new
      @users = User.all.order(:name)
    end

    def create
      @agent_principal = @agent.agent_principals.new(
        workspace: Current.workspace,
        user_id: params.dig(:agent_principal, :user_id),
        display_name: params.dig(:agent_principal, :display_name),
        role: params.dig(:agent_principal, :role)
      )

      if @agent_principal.save
        redirect_to admin_agent_path(@agent), notice: "Principal '#{@agent_principal.label}' added."
      else
        @users = User.all.order(:name)
        render :new, status: :unprocessable_entity
      end
    end

    def destroy
      principal = @agent.agent_principals.find(params[:id])
      principal.destroy
      redirect_to admin_agent_path(@agent), notice: "Principal removed."
    end

    private

    def set_agent
      @agent = Agent.find(params[:agent_id])
    end
  end
end
