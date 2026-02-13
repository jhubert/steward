class AddCredentialsToAgentPrincipals < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_principals, :credentials_json, :text
  end
end
