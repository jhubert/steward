class AgentPrincipal < ApplicationRecord
  include WorkspaceScoped

  belongs_to :agent
  belongs_to :user

  validates :agent_id, uniqueness: { scope: [:workspace_id, :user_id] }

  def label
    display_name.presence || user.name
  end

  def roster_entry
    if role.present?
      "#{label} (#{role})"
    else
      label
    end
  end
end
