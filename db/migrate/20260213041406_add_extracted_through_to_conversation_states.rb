class AddExtractedThroughToConversationStates < ActiveRecord::Migration[8.1]
  def change
    add_column :conversation_states, :extracted_through_message_id, :bigint
  end
end
