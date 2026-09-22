module Decisions
  # Client for TypeSafe's Jev — a "System One" model that returns typed,
  # calibrated decisions instead of text. Unstructured state in, a probability
  # out. It cannot generate, so it never replaces an Anthropic call that needs
  # to write something; it replaces the ones that only need to *decide*.
  #
  # One request carries a map of named questions, so fanning twenty judgments
  # out over the same state costs one round trip, not twenty. That is the whole
  # reason this is worth wiring in: per-item decisions we could never justify
  # at Haiku prices and Haiku latency become a single sub-second call.
  #
  # Every intended call site sits in the message-processing hot path, so this
  # degrades instead of raising. A missing key, a timeout, a 5xx, or a garbled
  # body all produce an empty Result whose readers return nil, and callers take
  # whatever path they took before Jev existed. Nothing here should ever be the
  # reason a user's message goes unanswered.
  class Jev
    ENDPOINT = "https://api.typesafe.ai/v1/systemone".freeze
    DEFAULT_MODEL = "jev-latest".freeze

    # Jev answers in 70-500ms. A generous timeout would only let a stalled
    # decision sit on the conversation advisory lock, so we give up fast and
    # let the caller fall back. Same reasoning as the 120s cap on the Anthropic
    # client, scaled to a model that is two orders of magnitude quicker.
    TIMEOUT_SECONDS = 5

    # Documented as retryable with exponential backoff.
    RETRY_STATUSES = [429, 529].freeze
    MAX_ATTEMPTS = 3
    BASE_BACKOFF = 0.25

    # API-documented shape limits. These are programmer errors rather than
    # runtime conditions, so they raise at build time instead of failing soft
    # on a request we already paid to send.
    MAX_CHOICE_OPTIONS = 255
    SCORE_LEVEL_RANGE = (2..10).freeze

    class << self
      # instructions and every criteria value accept an EntryType — a string,
      # or a structured object/array carrying definitions, contrasts,
      # exclusions, and examples. We pass those through untouched rather than
      # stringifying, because the structured form is how you pin down a
      # boundary Jev would otherwise read too literally.
      #
      # The one documented rule: don't mix plain strings and structured
      # objects within the same field of one question.

      # Builds a noul (yes/no returned as a probability 0..1).
      #
      # Jev reads instructions at face value and degrades on double negatives,
      # so phrase the proposition positively and so that high means yes:
      # "contains a durable fact" beats "is not free of durable facts".
      # Ask one condition per noul — use several when multiple labels apply.
      def noul(instructions, true_means: nil, false_means: nil)
        question = { "type" => "noul", "instructions" => instructions }
        if true_means || false_means
          question["criteria"] = { "true" => true_means, "false" => false_means }.compact
        end
        question
      end

      # Builds a choice over a hash of { option_key => description }, where a
      # description may itself be a hash such as
      #   { "what" => "...", "not_for" => "...", "examples" => [...] }
      #
      # Include an explicit no-match option whenever nothing may fit — Jev
      # always picks something from the set it is given.
      def choice(instructions, options)
        options = options.transform_keys(&:to_s)

        if options.size < 2
          raise ArgumentError, "choice needs at least 2 options, got #{options.size}"
        end
        if options.size > MAX_CHOICE_OPTIONS
          raise ArgumentError, "choice accepts at most #{MAX_CHOICE_OPTIONS} options, got #{options.size}"
        end

        { "type" => "choice", "instructions" => instructions, "criteria" => options }
      end

      # Builds a score over ordered levels, lowest first. Each level may be a
      # string or a structured entry; levels must describe concrete situations
      # and stand on their own rather than relying on the neighbours.
      def score(instructions, levels)
        levels = Array(levels)

        unless SCORE_LEVEL_RANGE.cover?(levels.size)
          raise ArgumentError,
                "score needs #{SCORE_LEVEL_RANGE.min}-#{SCORE_LEVEL_RANGE.max} levels, got #{levels.size}"
        end

        { "type" => "score", "instructions" => instructions, "criteria" => levels }
      end

      def configured?
        api_key.present?
      end

      def api_key
        ENV["TYPESAFE_API_KEY"] || Rails.application.credentials.dig(:typesafe, :api_key)
      end

      # Convenience for the common one-shot case.
      def ask(state:, questions:, model: DEFAULT_MODEL)
        new(model: model).call(state: state, questions: questions)
      end
    end

    def initialize(model: DEFAULT_MODEL)
      @model = model
    end

    # state:     String, Hash, or Array — the context to judge.
    # questions: { name => question_hash }, built via .noul / .choice / .score.
    #
    # Returns a Result. Never raises for network or API conditions.
    def call(state:, questions:)
      return Result.empty(reason: "not configured") unless self.class.configured?
      return Result.empty(reason: "no questions") if questions.blank?

      body = {
        "state" => state,
        "model" => @model,
        "questions" => questions.transform_keys(&:to_s)
      }

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = post_with_retries(body)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

      return Result.empty(reason: response[:error]) unless response[:ok]

      Result.new(payload: response[:payload], duration_ms: duration_ms)
    end

    private

    # Returns { ok: true, payload: Hash } or { ok: false, error: String }.
    # Retries only the conditions documented as transient; 401 and 422 are a
    # bad key and a bad request body, and retrying either just burns budget.
    def post_with_retries(body)
      last_error = nil

      MAX_ATTEMPTS.times do |i|
        outcome = attempt_post(body)

        return outcome[:result] if outcome[:result]

        last_error = outcome[:error]
        sleep(BASE_BACKOFF * (2**i)) if i < MAX_ATTEMPTS - 1
      end

      Rails.logger.warn("[Jev] Giving up after #{MAX_ATTEMPTS} attempts: #{last_error}")
      { ok: false, error: last_error }
    end

    # One request. Returns { result: ... } when the outcome is final either
    # way, or { error: ... } when it is worth another attempt.
    def attempt_post(body)
      response = HTTPX.with(timeout: { request_timeout: TIMEOUT_SECONDS })
                      .post(
                        ENDPOINT,
                        headers: {
                          "Authorization" => "Bearer #{self.class.api_key}",
                          "Content-Type" => "application/json"
                        },
                        json: body
                      )

      # HTTPX returns an ErrorResponse rather than raising on transport
      # failures, so this is the connection/timeout branch.
      if response.is_a?(HTTPX::ErrorResponse)
        return { error: "transport: #{response.error&.message}" }
      end

      status = response.status
      return { error: "http #{status}" } if RETRY_STATUSES.include?(status)

      unless (200..299).cover?(status)
        Rails.logger.warn("[Jev] HTTP #{status}: #{response.body.to_s.truncate(200)}")
        return { result: { ok: false, error: "http #{status}" } }
      end

      { result: { ok: true, payload: JSON.parse(response.body.to_s) } }
    rescue JSON::ParserError => e
      Rails.logger.warn("[Jev] Unparseable response: #{e.message}")
      { result: { ok: false, error: "unparseable response" } }
    rescue StandardError => e
      { error: "#{e.class}: #{e.message}" }
    end

    # Typed accessors over one response body. Unknown question names and
    # unanswered questions return nil so every caller has one uniform way to
    # detect "Jev did not tell me anything" and fall back.
    class Result
      attr_reader :duration_ms, :reason

      def self.empty(reason: nil)
        new(payload: nil, duration_ms: nil, reason: reason)
      end

      def initialize(payload:, duration_ms: nil, reason: nil)
        @payload = payload || {}
        @duration_ms = duration_ms
        @reason = reason
      end

      def ok?
        answers.any?
      end

      def answers
        @answers ||= (@payload["answers"] || {})
      end

      def usage
        @payload["usage"] || {}
      end

      def model
        @payload["model"]
      end

      # Probability 0..1 that the proposition is true. A noul carries no
      # separate confidence — the probability *is* the uncertainty.
      def noul(name)
        answer(name)&.dig("noul")
      end

      # The selected option key, or nil.
      def choice(name)
        answer(name)&.dig("choice")
      end

      # Continuous position across the level spectrum.
      def score(name)
        answer(name)&.dig("score")
      end

      # Full distribution for a choice or score.
      def probabilities(name)
        answer(name)&.dig("probabilities") || {}
      end

      # Score responses echo back the level labels keyed by index.
      def legend(name)
        answer(name)&.dig("legend") || {}
      end

      # The nearest named level for a score, e.g. 1.05 -> "Frustrated".
      # Useful for logging and for prompt text; branch on the raw score, not
      # on this, when the distance between levels carries meaning.
      def level(name)
        value = score(name)
        return nil if value.nil?

        legend(name)[value.round.to_s]
      end

      # Distribution concentration, 0..1, for choice and score. A noul has
      # none by design — its probability already describes the uncertainty.
      #
      # This measures how peaked the distribution is, NOT the likelihood the
      # answer is correct and NOT permission to act. Several equally
      # acceptable options spread probability and drag confidence down
      # without making any of them wrong.
      def confidence(name)
        answer(name)&.dig("confidence")
      end

      # The decision gate. Returns the choice only when Jev is confident
      # enough to act on it, otherwise nil so the caller escalates.
      #
      # Threshold belongs to the call site, not here: the bar for "which skill
      # to load" is nothing like the bar for "is this safe to send".
      def confident_choice(name, threshold)
        c = confidence(name)
        return nil if c.nil? || c < threshold

        choice(name)
      end

      # True only when the probability clears the bar. Nil probability (no
      # answer, failed call) is never "true" — an unanswered question must
      # not read as consent.
      #
      # Raise the bar when acting on a false yes is expensive; lower it when
      # missing a true yes is expensive. Thresholds are not transferable
      # between question types — a 0.8 that works on a noul means nothing as
      # a choice confidence, since Jev guarantees no arithmetic relationship
      # between the two.
      def yes?(name, threshold)
        p = noul(name)
        !p.nil? && p >= threshold
      end

      # Mirror of yes? for the negative case. Deliberately not `!yes?`: with
      # a yes bar of 0.8 and a no bar of 0.2, the band between them is the
      # "don't know" region that should escalate rather than decide, and an
      # unanswered question is neither a yes nor a no.
      def no?(name, threshold)
        p = noul(name)
        !p.nil? && p <= threshold
      end

      private

      def answer(name)
        answers[name.to_s]
      end
    end
  end
end
