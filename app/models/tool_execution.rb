class ToolExecution < ApplicationRecord
  include WorkspaceScoped

  belongs_to :agent_tool
  belongs_to :conversation
end
