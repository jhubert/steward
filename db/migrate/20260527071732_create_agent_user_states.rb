class CreateAgentUserStates < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_user_states do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :agent, null: false, foreign_key: true

      t.text :summary
      t.jsonb :pinned_facts, default: []
      t.jsonb :active_goals, default: []
      t.jsonb :outgoing_commitments, default: []
      t.text :scratchpad

      t.datetime :last_interaction_at
      t.datetime :last_summarized_at
      t.bigint :summarized_through_message_id

      t.timestamps
    end

    add_index :agent_user_states, [:workspace_id, :user_id, :agent_id],
              unique: true, name: "idx_agent_user_states_unique"
  end
end
