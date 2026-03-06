class PairingCode < ApplicationRecord
  include WorkspaceScoped

  belongs_to :agent
  belongs_to :created_by, class_name: "User"
  belongs_to :redeemed_by, class_name: "User", optional: true

  validates :code, presence: true, uniqueness: { scope: :workspace_id }
  validates :expires_at, presence: true

  def self.generate(agent:, created_by:, label: nil)
    code = SecureRandom.alphanumeric(6).upcase
    create!(
      workspace: agent.workspace,
      agent: agent,
      created_by: created_by,
      code: code,
      label: label,
      expires_at: 24.hours.from_now
    )
  end

  def self.find_valid(agent:, code:)
    return nil if code.blank?
    where(agent: agent, code: code.strip.upcase)
      .where(redeemed_at: nil)
      .where("expires_at > ?", Time.current)
      .first
  end

  def redeem!(user)
    update!(redeemed_by: user, redeemed_at: Time.current)
  end

  def expired?
    expires_at < Time.current
  end

  def redeemed?
    redeemed_at.present?
  end
end
