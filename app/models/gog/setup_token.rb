module Gog
  class SetupToken
    EXPIRY = 1.hour

    def self.generate(user:, agent:, workspace:)
      verifier.generate(
        { user_id: user.id, agent_id: agent.id, workspace_id: workspace.id },
        expires_in: EXPIRY
      )
    end

    def self.verify(token)
      data = verifier.verified(token, purpose: nil)
      return nil unless data

      data.symbolize_keys
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end

    def self.verifier
      Rails.application.message_verifier("gog_setup")
    end
  end
end
