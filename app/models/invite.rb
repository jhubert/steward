class Invite < ApplicationRecord
  include WorkspaceScoped

  belongs_to :invited_by, class_name: "User"
  belongs_to :user, optional: true

  STATUSES = %w[pending accepted revoked].freeze

  validates :email, presence: true, uniqueness: { scope: :workspace_id }
  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: %w[pending accepted]) }

  def self.allowed?(email)
    active.where(email: email.downcase).exists?
  end

  def accept!
    update!(status: "accepted")
  end

  def revoke!
    update!(status: "revoked")
  end

  def pending?
    status == "pending"
  end

  def accepted?
    status == "accepted"
  end

  def revoked?
    status == "revoked"
  end
end
