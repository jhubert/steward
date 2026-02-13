module Admin
  class BaseController < ActionController::Base
    layout "admin"
    before_action :set_workspace

    private

    def set_workspace
      Current.workspace = Workspace.find_by!(slug: "default")
    end
  end
end
