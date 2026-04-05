module Admin
  class BaseController < ActionController::Base
    layout "admin"
    before_action :set_workspace
    helper_method :current_workspace, :all_workspaces

    private

    def set_workspace
      if params[:workspace].present?
        session[:workspace_slug] = params[:workspace]
      end

      slug = session[:workspace_slug]
      Current.workspace = if slug.present?
        Workspace.find_by(slug: slug) || Workspace.order(:name).first!
      else
        Workspace.order(:name).first!
      end
    end

    def current_workspace
      Current.workspace
    end

    def all_workspaces
      Workspace.order(:name)
    end
  end
end
