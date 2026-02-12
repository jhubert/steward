class CreateAgents < ActiveRecord::Migration[8.1]
  def change
    create_table :agents do |t|
      t.references :workspace, null: false, foreign_key: true
      t.string :name, null: false
      t.text :system_prompt, null: false
      t.jsonb :settings, default: {}

      t.timestamps
    end
  end
end
