module Adapters
  class Email < Base
    API_BASE = "https://api.postmarkapp.com".freeze

    def initialize(server_token:)
      @server_token = server_token
    end

    def channel
      "email"
    end

    def normalize(raw_params)
      from = raw_params.dig("FromFull", "Email")
      return nil if from.blank?

      # Extract the agent handle from the To addresses
      to_list = raw_params["ToFull"] || []
      domain = email_domain
      agent_handle = to_list.filter_map { |to|
        addr = to["Email"].to_s.downcase
        local, host = addr.split("@", 2)
        local if host == domain
      }.first

      return nil if agent_handle.blank?

      # Prefer StrippedTextReply (strips quoted text), fall back to TextBody
      content = raw_params["StrippedTextReply"].presence || raw_params["TextBody"].presence || ""

      subject = raw_params["Subject"].to_s
      message_id = raw_params["MessageID"].to_s
      original_message_id = raw_params.dig("Headers")&.find { |h| h["Name"] == "Message-ID" }&.dig("Value")
      in_reply_to = raw_params.dig("Headers")&.find { |h| h["Name"] == "In-Reply-To" }&.dig("Value")
      references = raw_params.dig("Headers")&.find { |h| h["Name"] == "References" }&.dig("Value")

      from_name = raw_params.dig("FromFull", "Name").presence || from.split("@").first

      {
        user_external_key: "email",
        user_external_value: from.downcase,
        user_name: from_name,
        external_thread_key: from.downcase,
        content: content,
        agent_handle: agent_handle,
        metadata: {
          "email_message_id" => message_id,
          "email_subject" => subject,
          "email_original_message_id" => original_message_id,
          "email_in_reply_to" => in_reply_to,
          "email_references" => references
        }.compact
      }
    end

    def send_typing(_conversation)
      nil
    end

    def send_welcome_email(from_handle:, to_email:, subject:, body:)
      payload = {
        "From" => "#{from_handle}@#{email_domain}",
        "To" => to_email,
        "Subject" => subject,
        "TextBody" => body,
        "MessageStream" => "outbound"
      }

      response = HTTPX.post(
        "#{API_BASE}/email",
        headers: {
          "Accept" => "application/json",
          "Content-Type" => "application/json",
          "X-Postmark-Server-Token" => @server_token
        },
        json: payload
      )

      unless response.status == 200
        raise Adapters::DeliveryError, "Postmark send failed (#{response.status}): #{response.body}"
      end

      parsed = JSON.parse(response.body.to_s) rescue {}
      parsed["MessageID"]
    end

    def send_reply(conversation, message)
      agent = conversation.agent
      subject = conversation.metadata&.dig("email_subject") || "Message from #{agent.name}"
      subject = "Re: #{subject}" unless subject.start_with?("Re: ")

      to_email = conversation.external_thread_key

      # Build threading headers from conversation metadata
      headers = []
      original_msg_id = conversation.metadata&.dig("email_original_message_id")
      if original_msg_id
        headers << { "Name" => "In-Reply-To", "Value" => original_msg_id }
        headers << { "Name" => "References", "Value" => original_msg_id }
      end

      body = {
        "From" => "#{agent.email_handle}@#{email_domain}",
        "To" => to_email,
        "Subject" => subject,
        "TextBody" => message.content,
        "MessageStream" => "outbound"
      }
      body["Headers"] = headers if headers.any?

      response = HTTPX.post(
        "#{API_BASE}/email",
        headers: {
          "Accept" => "application/json",
          "Content-Type" => "application/json",
          "X-Postmark-Server-Token" => @server_token
        },
        json: body
      )

      unless response.status == 200
        raise Adapters::DeliveryError, "Postmark send failed (#{response.status}): #{response.body}"
      end

      # Store outbound MessageID in message metadata
      parsed = JSON.parse(response.body.to_s) rescue {}
      if parsed["MessageID"]
        message.update(metadata: (message.metadata || {}).merge("postmark_message_id" => parsed["MessageID"]))
      end

      response
    end

    private

    def email_domain
      Rails.application.credentials.dig(:postmark, :email_domain) || "withstuart.com"
    end
  end
end
