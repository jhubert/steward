module Admin
  class UsersController < BaseController
    def index
      scope = User.includes(:agent_principals).order(created_at: :desc)
      scope = scope.where("name ILIKE :q OR email ILIKE :q", q: "%#{params[:q]}%") if params[:q].present?

      @page = [params[:page].to_i, 1].max
      @per_page = 30
      @users = scope.offset((@page - 1) * @per_page).limit(@per_page + 1).to_a
      @has_next = @users.size > @per_page
      @users = @users.first(@per_page)
    end

    def show
      @user = User.find(params[:id])
      @conversations = @user.conversations.includes(:agent).order(updated_at: :desc).limit(20)
      @agent_principals = @user.agent_principals.includes(:agent)
      @memory_items = @user.memory_items.order(created_at: :desc).limit(20)
    end
  end
end
