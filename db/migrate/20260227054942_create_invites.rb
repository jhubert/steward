class CreateInvites < ActiveRecord::Migration[8.1]
  def change
    create_table :invites do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :invited_by, null: false, foreign_key: { to_table: :users }
      t.references :user, null: true, foreign_key: true
      t.string :email, null: false
      t.string :status, null: false, default: "pending"
      t.string :name

      t.timestamps
    end

    add_index :invites, [:workspace_id, :email], unique: true
  end
end
