module Email
  class PrincipalRouter
    def initialize(agent:)
      @agent = agent
    end

    # Returns the best AgentPrincipal to forward to, or nil if none have email contacts.
    def route(sender_name:, sender_email:, subject:, body:)
      candidates = @agent.agent_principals.includes(:user).select do |ap|
        ap.metadata&.dig("contact", "email").present?
      end

      return nil if candidates.empty?
      return candidates.first if candidates.size == 1

      pick_via_llm(candidates, sender_name: sender_name, sender_email: sender_email, subject: subject, body: body)
    end

    private

    def pick_via_llm(candidates, sender_name:, sender_email:, subject:, body:)
      roster = candidates.map.with_index do |ap, i|
        "#{i + 1}. #{ap.label} — #{ap.role}"
      end.join("\n")

      prompt = <<~PROMPT
        An email arrived for #{@agent.name} from #{sender_name} <#{sender_email}>.
        Subject: #{subject}
        Body preview: #{body.to_s[0, 500]}

        Which principal should receive this forwarded email?
        #{roster}

        Reply with ONLY the number (e.g. "1"). Nothing else.
      PROMPT

      response = Rails.configuration.anthropic_client.messages.create(
        model: @agent.extraction_model,
        max_tokens: 16,
        messages: [{ role: "user", content: prompt }]
      )

      choice = response.content.first.text.strip.scan(/\d+/).first&.to_i
      if choice && choice >= 1 && choice <= candidates.size
        candidates[choice - 1]
      else
        candidates.first
      end
    rescue => e
      Rails.logger.error("[PrincipalRouter] LLM call failed: #{e.message}")
      candidates.first
    end
  end
end
