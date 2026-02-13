module Admin
  class ConversationsController < BaseController
    def index
      @agents = Agent.all.order(:name)
      scope = Conversation.includes(:user, :agent).order(updated_at: :desc)
      scope = scope.where(agent_id: params[:agent_id]) if params[:agent_id].present?

      @page = [params[:page].to_i, 1].max
      @per_page = 30
      @conversations = scope.offset((@page - 1) * @per_page).limit(@per_page + 1).to_a
      @has_next = @conversations.size > @per_page
      @conversations = @conversations.first(@per_page)
    end

    def show
      @conversation = Conversation.includes(:user, :agent).find(params[:id])
      @messages = @conversation.messages.chronological
      @state = @conversation.state
    end
  end
end
