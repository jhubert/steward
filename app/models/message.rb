class Message < ApplicationRecord
  include WorkspaceScoped

  belongs_to :conversation
  belongs_to :user

  validates :role, presence: true, inclusion: { in: %w[user assistant system] }
  validates :content, presence: true

  scope :chronological, -> { order(:created_at) }
  scope :recent, ->(limit = 50) { chronological.last(limit) }
  scope :unsummarized_since, lambda { |message_id|
    scope = chronological
    scope = scope.where('id > ?', message_id) if message_id
    scope
  }
end
