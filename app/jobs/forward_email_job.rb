class ForwardEmailJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(agent_id, sender_name:, sender_email:, subject:, body:)
    agent = Agent.unscoped.find(agent_id)
    Current.workspace = agent.workspace

    return unless agent.email_handle.present?

    router = Email::PrincipalRouter.new(agent: agent)
    principal = router.route(
      sender_name: sender_name,
      sender_email: sender_email,
      subject: subject,
      body: body
    )

    unless principal
      Rails.logger.info("[ForwardEmail] No principal with email contact for agent #{agent.name} — dropping")
      return
    end

    to_email = principal.metadata.dig("contact", "email")

    forward_subject = "Fwd: #{subject}"
    forward_body = <<~BODY
      #{principal.label}, you have a new message forwarded by #{agent.name}.

      From: #{sender_name} <#{sender_email}>
      Subject: #{subject}

      ---

      #{body}
    BODY

    server_token = Rails.application.credentials.dig(:postmark, :server_token)
    adapter = Adapters::Email.new(server_token: server_token)
    adapter.send_new_email(
      from_handle: agent.email_handle,
      to: to_email,
      subject: forward_subject,
      body: forward_body
    )

    Rails.logger.info("[ForwardEmail] Forwarded email from #{sender_email} to #{principal.label} <#{to_email}> for agent #{agent.name}")
  end
end
