class PendingAction < ApplicationRecord
  include WorkspaceScoped

  STATUSES = %w[pending approved rejected expired failed].freeze
  DEFAULT_TTL = 24.hours

  belongs_to :agent
  belongs_to :conversation
  belongs_to :approver_user, class_name: "User"
  belongs_to :source_message, class_name: "Message", optional: true

  validates :tool_name, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: "pending") }

  before_validation :set_default_expiry, on: :create

  def pending?  = status == "pending"
  def approved? = status == "approved"
  def rejected? = status == "rejected"
  def expired?  = status == "expired"
  def failed?   = status == "failed"

  def resolved?
    !pending?
  end

  def expired_now?
    pending? && expires_at && expires_at < Time.current
  end

  def callback_data(decision)
    "pa:#{id}:#{decision}"
  end

  def self.parse_callback(data)
    return nil unless data.is_a?(String)
    m = data.match(/\Apa:(\d+):(\w+)\z/)
    return nil unless m
    { id: m[1].to_i, decision: m[2] }
  end

  private

  def set_default_expiry
    self.expires_at ||= Time.current + DEFAULT_TTL
  end
end
