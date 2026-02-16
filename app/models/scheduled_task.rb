class ScheduledTask < ApplicationRecord
  include WorkspaceScoped

  belongs_to :agent
  belongs_to :user
  belongs_to :conversation, optional: true
  belongs_to :agent_tool, optional: true

  validates :description, presence: true
  validates :next_run_at, presence: true
  validates :interval_seconds, numericality: { greater_than_or_equal_to: 60 }, allow_nil: true
  validate :agent_tool_belongs_to_same_agent

  def direct_execution?
    agent_tool_id.present?
  end

  scope :enabled, -> { where(enabled: true) }
  scope :due, -> { enabled.where("next_run_at <= ?", Time.current) }

  def recurring?
    interval_seconds.present?
  end

  def one_time?
    !recurring?
  end

  def advance!
    if recurring?
      new_next = next_run_at
      new_next += interval_seconds while new_next <= Time.current
      update!(next_run_at: new_next, last_run_at: Time.current)
    else
      update!(enabled: false, last_run_at: Time.current)
    end
  end

  FAILURE_NOTIFY_THRESHOLD = 3

  def record_success!
    update!(consecutive_failures: 0) if consecutive_failures > 0
  end

  def record_failure!
    increment!(:consecutive_failures)
  end

  def failure_threshold_reached?
    consecutive_failures >= FAILURE_NOTIFY_THRESHOLD
  end

  def cancel!
    update!(enabled: false)
  end

  def interval_description
    return "once" unless recurring?

    case interval_seconds
    when 3600 then "hourly"
    when 86_400 then "daily"
    when 604_800 then "weekly"
    else "every #{interval_seconds} seconds"
    end
  end

  private

  def agent_tool_belongs_to_same_agent
    return unless agent_tool_id.present?
    return if agent_tool&.agent_id == agent_id

    errors.add(:agent_tool, "must belong to the same agent")
  end
end
