module Adapters
  class DeliveryError < StandardError; end

  class Base
    # Normalize raw input from a channel into a standard hash.
    # Returns: { workspace_id:, user_external_key:, user_external_value:,
    #            user_name:, external_thread_key:, content:, metadata: }
    def normalize(raw_params)
      raise NotImplementedError
    end

    # Send the assistant's reply back through the channel.
    # Raises Adapters::DeliveryError on failure.
    def send_reply(conversation, message)
      raise NotImplementedError
    end

    # The channel identifier string (e.g. "telegram", "email").
    def channel
      raise NotImplementedError
    end
  end
end
