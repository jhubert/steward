module Decisions
  # Decides whether an agent-initiated message is worth interrupting someone
  # for. A capable colleague doesn't message you to say nothing happened;
  # Jennifer currently does, roughly 500 times.
  #
  # This gates DELIVERY only. The reply is already composed and persisted by
  # the time we get here, and all the agent's real work — the email check, the
  # PR review, the digest that actually went out — has already happened. A
  # held message stays in conversation history where `recall`, the timeline,
  # and compaction all still see it. The only thing suppressed is the buzz.
  #
  # Scope is deliberately narrow: only messages the agent started on its own
  # (scheduled tasks and other triggers). Silence in reply to something a
  # human typed isn't restraint, it's a broken bot.
  #
  # Fails OPEN. An unconfigured key, a timeout, or an unparseable answer all
  # deliver. Staying quiet about something that mattered is the expensive
  # error; one redundant ping is not.
  class DeliveryGate
    OFF       = "off".freeze
    SHADOW    = "shadow".freeze
    ENFORCING = "enforcing".freeze
    MODES = [OFF, SHADOW, ENFORCING].freeze

    # The agent's own stated intent outranks anything we infer. When it says
    # not to notify, that's a decision, not a signal to weigh against others.
    SELF_DECLARED = 0.70
    # A standing "tell me every time" beats the nothing-happened heuristics.
    STANDING      = 0.70
    # Anything the recipient must act on goes through.
    NEEDS         = 0.50
    # Hold only when it's clearly routine AND clearly eventless.
    CONFIRMS      = 0.80
    EVENT_FLOOR   = 0.35
    # Or when nothing happened at all, regardless of framing.
    NO_EVENT      = 0.15

    Decision = Struct.new(
      :deliver, :reason, :signals, :duration_ms, :input_tokens, :mode,
      keyword_init: true
    ) do
      def held? = !deliver
    end

    def self.mode_for(agent)
      mode = agent.settings&.dig("delivery_gate").to_s
      MODES.include?(mode) ? mode : OFF
    end

    # True only for messages the agent initiated itself. Agent#trigger stamps
    # source=trigger on a background conversation; both must hold, so a human
    # typing into a background thread is never gated.
    def self.applicable?(conversation, source_message)
      return false unless conversation&.background?
      source_message&.metadata&.dig("source") == "trigger"
    end

    def initialize(agent:, conversation:, reply:, source_message:)
      @agent = agent
      @conversation = conversation
      @reply = reply
      @source_message = source_message
    end

    # agent_declared_silent: the agent called stay_silent this turn. That's an
    # explicit structured decision, so we honour it without spending a call —
    # and without depending on how it happened to phrase itself.
    def call(agent_declared_silent: false)
      if agent_declared_silent
        return Decision.new(deliver: false, reason: "agent called stay_silent",
                            signals: { "declared" => true }, mode: mode)
      end

      return deliver_by_default("gate off") unless mode != OFF
      return deliver_by_default("not configured") unless Jev.configured?
      return deliver_by_default("empty reply") if @reply&.content.blank?

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Jev.ask(state: state, questions: QUESTIONS)
      elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

      return deliver_by_default("jev unavailable: #{result.reason}") unless result.ok?

      signals = QUESTIONS.keys.to_h { |k| [k.to_s, result.noul(k)] }
      deliver, reason = decide(signals)

      Decision.new(deliver: deliver, reason: reason, signals: signals,
                   duration_ms: elapsed, input_tokens: result.usage["input_tokens"],
                   mode: mode)
    end

    def mode
      @mode ||= self.class.mode_for(@agent)
    end

    private

    def deliver_by_default(reason)
      Decision.new(deliver: true, reason: reason, signals: {}, mode: mode)
    end

    # Ordering is the policy. Read top to bottom: explicit intent, then things
    # that force a send, then the two ways of saying nothing happened.
    def decide(s)
      silent   = s["self_declared_silent"].to_f
      standing = s["standing_request"].to_f
      needs    = s["needs_recipient"].to_f
      confirms = s["merely_confirms"].to_f
      event    = s["reports_event"].to_f

      return [false, "agent said not to notify"] if silent >= SELF_DECLARED
      return [true,  "standing request"]         if standing >= STANDING
      return [true,  "needs recipient"]          if needs >= NEEDS
      return [false, "routine confirmation only"] if confirms >= CONFIRMS && event <= EVENT_FLOOR
      return [false, "no event reported"]        if event <= NO_EVENT

      [true, "default send"]
    end

    # Named fields, filtered down to what the questions actually need — Jev
    # loses accuracy as irrelevant context grows.
    def state
      {
        "recipient" => recipient_description,
        "assistant" => @agent.name,
        "task_description" => task_description,
        "draft_message" => @reply.content.to_s.truncate(1500)
      }
    end

    def recipient_description
      name = @conversation.user.try(:display_name).presence ||
             @conversation.user.try(:name).presence || "the recipient"
      "#{name}, who receives this as a push notification on their phone"
    end

    def task_description
      raw = @source_message&.content.to_s
      raw[/\[Scheduled Task:?([^\]]*)\]/, 1]&.strip.presence ||
        raw.truncate(300).presence ||
        "(unspecified background task)"
    end

    # One narrow condition per noul, each phrased so that high always means
    # "more reason to send". Nothing here needs mental inversion, which is
    # where Jev's literal reading tends to bite.
    QUESTIONS = {
      reports_event: Jev.noul(
        "`draft_message` reports a concrete event, result, or change that actually occurred.",
        true_means: {
          "what" => "Describes something specific that happened: work completed, a decision made, a change landed, or a message received that needs an answer",
          "examples" => ["Shannon opened PR #1110 deleting the rake task", "Jeremy closed #1109 without merging"]
        },
        false_means: {
          "what" => "Reports that nothing happened, that a routine check found nothing new, or that a scheduled action ran as expected",
          "examples" => ["Quiet day on main: nothing merged", "Nothing actionable", "Digest sent as scheduled"]
        }
      ),
      needs_recipient: Jev.noul(
        "`recipient` needs to read this now: it asks them something, or tells them something that changes what they would do next.",
        true_means: "Contains a question for the recipient, a decision they must make, or information that alters their plans",
        false_means: "Purely informational narration the recipient could read later or never"
      ),
      merely_confirms: Jev.noul(
        "`draft_message` mainly confirms that an automated routine completed as expected.",
        true_means: "The substance is that the scheduled thing ran, with no finding that would matter on its own",
        false_means: "There is a finding that would matter even if no routine had been scheduled"
      ),
      standing_request: Jev.noul(
        "`task_description` shows the recipient asked to be told the outcome every time this runs, including when there is nothing to report."
      ),
      # Agents already state this in prose and the pipeline delivers the
      # sentence as a notification. Reading it back out is a literal question
      # about text in hand — the kind Jev is most reliable on.
      self_declared_silent: Jev.noul(
        "`draft_message` states that the recipient does not need to be notified about this.",
        true_means: {
          "what" => "The text explicitly says no notification, ping, or alert is needed, or that it is being noted silently",
          "examples" => ["No notification needed", "No Telegram ping warranted", "Silently noted, not notifying Jeremy"]
        },
        false_means: "The text makes no claim about whether the recipient should be notified"
      )
    }.freeze
  end
end
