class MemoryItem < ApplicationRecord
  include WorkspaceScoped

  belongs_to :user
  belongs_to :conversation, optional: true

  validates :content, presence: true
end
