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

      # Extract the agent handle from To + Cc addresses
      to_list = raw_params["ToFull"] || []
      cc_list = raw_params["CcFull"] || []
      domain = email_domain
      agent_handle = (to_list + cc_list).filter_map { |entry|
        addr = entry["Email"].to_s.downcase
        local, host = addr.split("@", 2)
        local if host == domain
      }.first

      return nil if agent_handle.blank?

      # Prefer StrippedTextReply (strips quoted text), fall back to TextBody
      content = raw_params["StrippedTextReply"].presence || raw_params["TextBody"].presence || ""

      subject = raw_params["Subject"].to_s
      message_id = raw_params["MessageID"].to_s
      original_message_id = find_header(raw_params, "Message-ID")
      in_reply_to = find_header(raw_params, "In-Reply-To")
      references = find_header(raw_params, "References")

      from_name = raw_params.dig("FromFull", "Name").presence || from.split("@").first

      # Derive thread key from RFC 5322 headers
      thread_key = derive_thread_key(references, in_reply_to, original_message_id)

      # Collect all thread participants (To + Cc + From, minus the agent)
      agent_email = "#{agent_handle}@#{domain}"
      participants = collect_participants(raw_params, agent_email)

      result = {
        user_external_key: "email",
        user_external_value: from.downcase,
        user_name: from_name,
        external_thread_key: thread_key,
        content: content,
        agent_handle: agent_handle,
        participants: participants,
        metadata: {
          "email_message_id" => message_id,
          "email_subject" => subject,
          "email_original_message_id" => original_message_id,
          "email_in_reply_to" => in_reply_to,
          "email_references" => references,
          "sender_email" => from.downcase,
          "sender_name" => from_name
        }.compact
      }

      # Pass through raw attachments for processing in the controller
      raw_attachments = raw_params["Attachments"]
      result[:raw_attachments] = raw_attachments if raw_attachments.present?

      result
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
        "HtmlBody" => EmailFormatter.to_html(body),
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

      agent_email = "#{agent.email_handle}@#{email_domain}"
      participants = conversation.metadata&.dig("email_participants") || []
      last_sender = conversation.metadata&.dig("last_sender_email")

      # To: the most recent inbound sender, falling back to conversation owner's email
      to_email = last_sender || conversation.user.email || conversation.external_thread_key
      # Cc: all other participants except the To recipient and the agent
      cc_emails = participants
        .map { |p| p["email"] }
        .reject { |e| e == to_email.downcase || e == agent_email.downcase }
        .uniq

      # Build threading headers from conversation metadata
      headers = build_threading_headers(conversation)

      body = {
        "From" => agent_email,
        "To" => to_email,
        "Subject" => subject,
        "TextBody" => message.content,
        "HtmlBody" => EmailFormatter.to_html(message.content),
        "MessageStream" => "outbound"
      }
      body["Cc"] = cc_emails.join(", ") if cc_emails.any?
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

      # Store outbound Message-ID for future threading
      parsed = JSON.parse(response.body.to_s) rescue {}
      if parsed["MessageID"]
        message.update(metadata: (message.metadata || {}).merge("postmark_message_id" => parsed["MessageID"]))

        # Track the outbound Message-ID in conversation metadata for References chain
        outbound_id = "<#{parsed['MessageID']}@mtasv.net>"
        refs = conversation.metadata&.dig("email_references_chain") || []
        refs << outbound_id
        conversation.update!(metadata: (conversation.metadata || {}).merge(
          "last_outbound_message_id" => outbound_id,
          "email_references_chain" => refs.last(50)
        ))
      end

      response
    end

    def send_new_email(from_handle:, to:, cc: nil, subject:, body:)
      agent_email = "#{from_handle}@#{email_domain}"

      payload = {
        "From" => agent_email,
        "To" => to,
        "Subject" => subject,
        "TextBody" => body,
        "HtmlBody" => EmailFormatter.to_html(body),
        "MessageStream" => "outbound"
      }
      payload["Cc"] = cc if cc.present?

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

    private

    # Derive a stable thread key from RFC 5322 email headers.
    # - References present → first Message-ID (the thread root)
    # - Only In-Reply-To → use that
    # - Neither (new thread) → use this email's own Message-ID
    def derive_thread_key(references, in_reply_to, original_message_id)
      if references.present?
        # References is space-separated list of Message-IDs; first is the thread root
        first_ref = references.strip.split(/\s+/).first
        return first_ref if first_ref.present?
      end

      return in_reply_to if in_reply_to.present?

      return original_message_id if original_message_id.present?

      # Fallback: generate a unique key (shouldn't happen with valid emails)
      SecureRandom.uuid
    end

    # Collect all participants from To, Cc, and From — excluding the agent's address.
    def collect_participants(raw_params, agent_email)
      agent_email_down = agent_email.downcase
      participants = []

      # From
      from_full = raw_params["FromFull"]
      if from_full
        email = from_full["Email"].to_s.downcase
        unless email == agent_email_down
          participants << { "email" => email, "name" => from_full["Name"].presence || email.split("@").first }
        end
      end

      # To + Cc
      (raw_params["ToFull"] || []).concat(raw_params["CcFull"] || []).each do |entry|
        email = entry["Email"].to_s.downcase
        next if email == agent_email_down
        next if participants.any? { |p| p["email"] == email }
        participants << { "email" => email, "name" => entry["Name"].presence || email.split("@").first }
      end

      participants
    end

    # Case-insensitive header lookup — email header names vary by client
    # (e.g. Gmail uses "Message-ID", Apple Mail uses "Message-Id").
    def find_header(raw_params, name)
      raw_params.dig("Headers")&.find { |h| h["Name"].to_s.casecmp?(name) }&.dig("Value")
    end

    # Build In-Reply-To and References headers for threading.
    def build_threading_headers(conversation)
      headers = []
      meta = conversation.metadata || {}

      last_outbound = meta["last_outbound_message_id"]
      last_inbound = meta["email_original_message_id"]

      # In-Reply-To: prefer the most recent inbound (the message we're replying to),
      # fall back to our own last outbound (which the recipient also has).
      reply_to = last_inbound || last_outbound
      if reply_to
        headers << { "Name" => "In-Reply-To", "Value" => reply_to }
      end

      # References: build full chain
      refs_chain = meta["email_references_chain"] || []
      if last_inbound && !refs_chain.include?(last_inbound)
        refs_chain = [last_inbound] + refs_chain
      end
      if refs_chain.any?
        headers << { "Name" => "References", "Value" => refs_chain.join(" ") }
      end

      headers
    end

    def email_domain
      Rails.application.credentials.dig(:postmark, :email_domain) || "withstuart.com"
    end
  end
end
