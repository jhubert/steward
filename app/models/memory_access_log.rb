class MemoryAccessLog < ApplicationRecord
  include WorkspaceScoped

  belongs_to :agent
  belongs_to :viewing_user, class_name: "User"
  belongs_to :subject_user, class_name: "User"
  belongs_to :conversation, optional: true

  validates :context, presence: true

  # Cheap insert-only audit trail. Callers should fire-and-forget — failures
  # here must NEVER block prompt rendering or tool execution.
  def self.record(workspace:, agent:, viewing_user:, conversation: nil, context:,
                  subject_user: nil, subject_user_id: nil, memory_item_id: nil)
    attrs = {
      workspace: workspace,
      agent: agent,
      viewing_user: viewing_user,
      conversation: conversation,
      context: context.to_s,
      memory_item_id: memory_item_id
    }
    if subject_user
      attrs[:subject_user] = subject_user
    elsif subject_user_id
      attrs[:subject_user_id] = subject_user_id
    end

    create!(**attrs)
  rescue StandardError => e
    Rails.logger.warn("[MemoryAccessLog] failed to record: #{e.message}")
    nil
  end
end
