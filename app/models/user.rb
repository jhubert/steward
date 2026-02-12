class User < ApplicationRecord
  include WorkspaceScoped

  has_many :conversations, dependent: :destroy
  has_many :messages, dependent: :destroy
  has_many :memory_items, dependent: :destroy

  validates :email, uniqueness: { scope: :workspace_id }, allow_nil: true

  # Find a user by their external identifier for a given channel.
  # e.g. User.find_by_external("telegram_chat_id", "123456")
  def self.find_by_external(key, value)
    where('external_ids @> ?', { key => value }.to_json).first
  end
end
