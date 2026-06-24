class NullifyPendingActionSourceMessageOnDelete < ActiveRecord::Migration[8.1]
  # ProcessMessageJob destroys ephemeral system_instruction carrier messages
  # after they're processed. When such a carrier triggers a new pending_action
  # (e.g., a model that produces a fresh email tool call mid-system-instruction)
  # the message's destruction violates the original RESTRICT FK. Switch to
  # ON DELETE SET NULL — pending_actions don't structurally need the message
  # to survive; it's just provenance.
  def up
    remove_foreign_key :pending_actions, column: :source_message_id
    add_foreign_key :pending_actions, :messages,
                    column: :source_message_id,
                    on_delete: :nullify
  end

  def down
    remove_foreign_key :pending_actions, column: :source_message_id
    add_foreign_key :pending_actions, :messages, column: :source_message_id
  end
end
