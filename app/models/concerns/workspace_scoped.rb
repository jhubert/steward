module WorkspaceScoped
  extend ActiveSupport::Concern

  included do
    belongs_to :workspace

    default_scope -> { where(workspace: Current.workspace) if Current.workspace }
  end
end
