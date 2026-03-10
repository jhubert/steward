class User < ApplicationRecord
  include WorkspaceScoped

  has_many :conversations, dependent: :destroy
  has_many :messages, dependent: :destroy
  has_many :memory_items, dependent: :destroy
  has_many :agent_principals, dependent: :destroy
  has_many :principal_agents, through: :agent_principals, source: :agent

  validates :email, uniqueness: { scope: :workspace_id }, allow_nil: true

  # Find a user by their external identifier for a given channel.
  # e.g. User.find_by_external("telegram_chat_id", "123456")
  def self.find_by_external(key, value)
    where('external_ids @> ?', { key => value }.to_json).first
  end

  # Find a user by any of their email addresses.
  # Checks external_ids["emails"] array, then falls back to the email column.
  def self.find_by_email_address(email)
    return nil if email.blank?
    find_by_external_email(email) || find_by(email: email)
  end

  # Add an email address to the user's emails array (deduplicates).
  def add_email!(email)
    emails = external_ids&.dig("emails") || []
    return if emails.include?(email.downcase)
    emails << email.downcase
    update!(external_ids: (external_ids || {}).merge("emails" => emails))
  end

  # Merge duplicate user records into a primary user.
  # Combines external_ids, reassigns all associated records, deletes duplicates.
  # Must be called with fully instantiated User objects (not IDs).
  def self.merge!(primary, *duplicates)
    duplicates = duplicates.flatten.compact
    raise ArgumentError, "No duplicates to merge" if duplicates.empty?
    raise ArgumentError, "Cannot merge a user into itself" if duplicates.any? { |d| d.id == primary.id }

    ActiveRecord::Base.transaction do
      # 1. Merge external_ids into primary
      merged_ids = primary.external_ids || {}
      duplicates.each do |dup|
        (dup.external_ids || {}).each do |key, value|
          if value.is_a?(Array) && merged_ids[key].is_a?(Array)
            merged_ids[key] = (merged_ids[key] + value).uniq
          elsif merged_ids[key].nil?
            merged_ids[key] = value
          end
        end
      end
      primary.update!(external_ids: merged_ids)

      # Set primary email if blank
      if primary.email.blank?
        donor_email = duplicates.find { |d| d.email.present? }&.email
        primary.update!(email: donor_email) if donor_email
      end

      dup_ids = duplicates.map(&:id)

      # 2. Reassign simple belongs_to :user records (no unique constraints)
      Message.unscoped.where(user_id: dup_ids).update_all(user_id: primary.id)
      MemoryItem.unscoped.where(user_id: dup_ids).update_all(user_id: primary.id)
      ConversationState.unscoped.where(user_id: dup_ids).update_all(user_id: primary.id)
      ScheduledTask.unscoped.where(user_id: dup_ids).update_all(user_id: primary.id)
      Invite.unscoped.where(invited_by_id: dup_ids).update_all(invited_by_id: primary.id)
      Invite.unscoped.where(user_id: dup_ids).update_all(user_id: primary.id)
      PairingCode.unscoped.where(created_by_id: dup_ids).update_all(created_by_id: primary.id)
      PairingCode.unscoped.where(redeemed_by_id: dup_ids).update_all(redeemed_by_id: primary.id)

      # 3. Conversations — unique index on (workspace, user, agent, channel, external_thread_key) for non-email
      # Reassign where no conflict; delete duplicates that would violate the unique index
      Conversation.unscoped.where(user_id: dup_ids).find_each do |conv|
        existing = Conversation.unscoped.find_by(
          workspace_id: conv.workspace_id,
          user_id: primary.id,
          agent_id: conv.agent_id,
          channel: conv.channel,
          external_thread_key: conv.external_thread_key
        )
        if existing
          # Move messages and states to the existing conversation, then delete the duplicate
          Message.unscoped.where(conversation_id: conv.id).update_all(conversation_id: existing.id, user_id: primary.id)
          ConversationState.unscoped.where(conversation_id: conv.id).delete_all
          ScheduledTask.unscoped.where(conversation_id: conv.id).update_all(conversation_id: existing.id)
          conv.delete
        else
          conv.update_columns(user_id: primary.id)
        end
      end

      # 4. AgentPrincipals — unique index on (workspace, agent, user)
      AgentPrincipal.unscoped.where(user_id: dup_ids).find_each do |ap|
        existing = AgentPrincipal.unscoped.find_by(
          workspace_id: ap.workspace_id,
          agent_id: ap.agent_id,
          user_id: primary.id
        )
        if existing
          ap.delete
        else
          ap.update_columns(user_id: primary.id)
        end
      end

      # 5. Delete the duplicate user records
      User.unscoped.where(id: dup_ids).delete_all
    end

    primary.reload
  end

  private

  def self.find_by_external_email(email)
    where("external_ids->'emails' @> ?", [email].to_json).first
  end
end
