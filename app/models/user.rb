class User < ApplicationRecord
  include WorkspaceScoped

  has_many :conversations, dependent: :destroy
  has_many :messages, dependent: :destroy
  has_many :memory_items, dependent: :destroy
  has_many :agent_principals, dependent: :destroy
  has_many :principal_agents, through: :agent_principals, source: :agent

  validates :email, uniqueness: { scope: :workspace_id }, allow_nil: true

  # Find a user by their external identifier for a given channel.
  # e.g. User.find_by_external("telegram_chat_id", "123456")
  def self.find_by_external(key, value)
    where('external_ids @> ?', { key => value }.to_json).first
  end

  # Find a user by any of their email addresses.
  # Checks external_ids["emails"] array, then falls back to the email column.
  def self.find_by_email_address(email)
    return nil if email.blank?
    find_by_external_email(email) || find_by(email: email)
  end

  # Add an email address to the user's emails array (deduplicates).
  def add_email!(email)
    emails = external_ids&.dig("emails") || []
    return if emails.include?(email.downcase)
    emails << email.downcase
    update!(external_ids: (external_ids || {}).merge("emails" => emails))
  end

  private

  def self.find_by_external_email(email)
    where("external_ids->'emails' @> ?", [email].to_json).first
  end
end
