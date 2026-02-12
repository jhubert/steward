class AddAutonomyFieldsToConversationStates < ActiveRecord::Migration[8.1]
  def change
    add_column :conversation_states, :tool_log, :jsonb, default: []
    add_column :conversation_states, :scratchpad, :text, default: ""
  end
end
