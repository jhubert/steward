module Tools
  module EmailGate
    # Verifies that a reply draft actually engages with the inbound message —
    # the draft must contain at least one non-trivial literal substring from
    # the inbound body. Cheap defense against the fabrication failure mode
    # where an agent answers questions that were never asked.
    class QuoteBack
      MIN_SUBSTRING = 15
      MIN_WORDS = 3

      Result = Struct.new(:ok?, :reason, keyword_init: true)

      def initialize(min_substring: MIN_SUBSTRING, min_words: MIN_WORDS)
        @min_substring = min_substring
        @min_words = min_words
      end

      # Returns ok? true if the draft contains a substring of at least
      # @min_substring characters (spanning @min_words+ tokens) drawn from
      # the inbound body. Normalization: lowercase, collapse whitespace,
      # strip punctuation from edges of the search windows.
      def call(inbound_body:, draft_body:)
        inbound = normalize(inbound_body)
        draft = normalize(draft_body)

        return Result.new(ok?: false, reason: "inbound message is empty; cannot verify reply grounding") if inbound.strip.empty?
        return Result.new(ok?: false, reason: "draft reply is empty") if draft.strip.empty?

        # Slide a window of min_substring chars across the inbound and check
        # for presence in the draft. Require the match to span at least
        # min_words words to rule out matches on common boilerplate like
        # "thanks for the" or sender signatures.
        (0..(inbound.length - @min_substring)).each do |i|
          window = inbound[i, @min_substring]
          next if window.split(/\s+/).reject(&:empty?).size < @min_words
          return Result.new(ok?: true, reason: "quote matched: #{window.strip.inspect}") if draft.include?(window)
        end

        Result.new(
          ok?: false,
          reason: "no literal substring of #{@min_substring}+ characters from the inbound message appears in the draft reply. If your reply is grounded in what the sender wrote, include a direct quote. If you must reply without quoting, escalate to Jeremy via send_message instead."
        )
      end

      private

      def normalize(str)
        str.to_s
          .gsub(/\r\n?/, "\n")
          .gsub(/\s+/, " ")
          .downcase
      end
    end
  end
end
