class ScheduledTask < ApplicationRecord
  include WorkspaceScoped

  belongs_to :agent
  belongs_to :conversation

  validates :description, presence: true
  validates :next_run_at, presence: true
  validates :interval_seconds, numericality: { greater_than_or_equal_to: 60 }, allow_nil: true

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
end
