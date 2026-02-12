class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.references :workspace, null: false, foreign_key: true
      t.string :name
      t.string :email
      t.jsonb :external_ids, default: {}

      t.timestamps
    end

    add_index :users, %i[workspace_id email], unique: true, where: 'email IS NOT NULL'
  end
end
