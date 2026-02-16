class AgentPrincipal < ApplicationRecord
  include WorkspaceScoped

  encrypts :credentials_json

  belongs_to :agent
  belongs_to :user

  validates :agent_id, uniqueness: { scope: [:workspace_id, :user_id] }

  def label
    display_name.presence || user.name
  end

  def roster_entry
    if role.present?
      "#{label} (#{role})"
    else
      label
    end
  end

  def contact_details
    contact = metadata&.dig("contact")
    return nil if contact.blank?

    parts = []
    parts << "Email: #{contact['email']}" if contact["email"].present?
    parts << "Phone: #{contact['phone']}" if contact["phone"].present?
    contact.except("email", "phone").each do |key, value|
      parts << "#{key.titleize}: #{value}" if value.present?
    end
    parts.presence&.join(", ")
  end

  def credentials
    return {} if credentials_json.blank?
    JSON.parse(credentials_json)
  rescue JSON::ParserError
    {}
  end

  def credentials=(hash)
    self.credentials_json = hash.present? ? hash.to_json : nil
  end
end
