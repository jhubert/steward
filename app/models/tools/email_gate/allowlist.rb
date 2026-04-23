module Tools
  module EmailGate
    # Determines whether a set of recipients is allowed for a given agent.
    # Rules:
    # - Principals (registered users of the agent) are always allowed
    # - Addresses the agent has received inbound mail from are allowed
    # - Addresses explicitly listed in agent.settings["email_allowlist"] are allowed
    # - Anything else is blocked (first-time outbound to a stranger needs approval)
    class Allowlist
      Result = Struct.new(:ok?, :blocked, :allowed, keyword_init: true)

      def initialize(agent)
        @agent = agent
      end

      def call(recipients)
        addrs = Array(recipients).flat_map { |r| split_addresses(r) }.map(&:downcase).uniq
        return Result.new(ok?: true, blocked: [], allowed: []) if addrs.empty?

        allowed_set = allowed_addresses
        blocked = addrs.reject { |a| allowed_set.include?(a) }
        Result.new(ok?: blocked.empty?, blocked: blocked, allowed: addrs - blocked)
      end

      private

      def allowed_addresses
        @allowed_addresses ||= (principal_emails + inbound_senders + explicit_allowlist).map(&:downcase).to_set
      end

      def principal_emails
        return [] unless @agent.respond_to?(:agent_principals)
        @agent.agent_principals.flat_map do |ap|
          emails = ap.user&.external_ids&.dig("emails") || []
          ([ap.user&.email] + emails + [ap.display_name&.match(/<(.+?)>/)&.[](1)]).compact
        end
      end

      def inbound_senders
        Conversation.unscoped
          .where(workspace_id: @agent.workspace_id, agent_id: @agent.id, channel: "email")
          .flat_map do |conv|
            (conv.metadata&.dig("email_participants") || []).map { |p| p.is_a?(Hash) ? p["email"] : p.to_s }
          end.compact
      end

      def explicit_allowlist
        @agent.settings&.dig("email_allowlist") || []
      end

      def split_addresses(str)
        str.to_s.split(",").map { |s| s.strip.sub(/.*<([^>]+)>.*/, '\1') }.reject(&:empty?)
      end
    end
  end
end
