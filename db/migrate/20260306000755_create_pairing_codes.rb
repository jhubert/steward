class CreatePairingCodes < ActiveRecord::Migration[8.1]
  def change
    create_table :pairing_codes do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :agent, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.references :redeemed_by, foreign_key: { to_table: :users }
      t.string :code, null: false
      t.string :label
      t.datetime :expires_at, null: false
      t.datetime :redeemed_at
      t.timestamps
    end
    add_index :pairing_codes, [:workspace_id, :code], unique: true
  end
end
