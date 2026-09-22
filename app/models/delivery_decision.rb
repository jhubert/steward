class DeliveryDecision < ApplicationRecord
  include WorkspaceScoped

  belongs_to :agent
  belongs_to :conversation
  belongs_to :message, optional: true

  scope :shadow, -> { where(mode: Decisions::DeliveryGate::SHADOW) }
  scope :enforcing, -> { where(mode: Decisions::DeliveryGate::ENFORCING) }

  # Shadow mode's payload: messages that were delivered but wouldn't have been.
  # Reviewing these is how you decide whether to enforce.
  scope :would_have_held, -> { where(would_deliver: false, delivered: true) }
  scope :held, -> { where(delivered: false) }

  def signal(name)
    signals&.dig(name.to_s)
  end

  # Compact one-line summary for review output.
  def to_review_line
    "#{created_at.strftime('%Y-%m-%d %H:%M')}  #{reason.ljust(28)} " \
      "#{message&.content.to_s.gsub(/\s+/, ' ').truncate(120)}"
  end
end
