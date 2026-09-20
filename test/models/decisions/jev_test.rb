require "test_helper"

module Decisions
  class JevTest < ActiveSupport::TestCase
    # A representative body in the documented response shape.
    PAYLOAD = {
      "model" => "jev-1.13.0",
      "answers" => {
        "is_urgent" => { "type" => "noul", "noul" => 0.93 },
        "route" => {
          "type" => "choice",
          "choice" => "billing",
          "probabilities" => { "billing" => 0.88, "technical" => 0.12 },
          "confidence" => 0.81
        },
        "frustration" => {
          "type" => "score",
          "score" => 1.05,
          "confidence" => 0.44,
          "legend" => { "0" => "Calm", "1" => "Frustrated", "2" => "Very angry" }
        }
      },
      "usage" => { "input_tokens" => 296, "output_tokens" => 20 }
    }.freeze

    def result(payload = PAYLOAD)
      Jev::Result.new(payload: payload)
    end

    # --- question builders -------------------------------------------------

    test "noul builder omits criteria when no meanings given" do
      q = Jev.noul("Does this convey urgency?")
      assert_equal "noul", q["type"]
      assert_not q.key?("criteria")
    end

    test "noul builder includes both criteria when given" do
      q = Jev.noul("Urgent?", true_means: "Time-sensitive", false_means: "Not")
      assert_equal({ "true" => "Time-sensitive", "false" => "Not" }, q["criteria"])
    end

    test "choice builder rejects fewer than two options" do
      assert_raises(ArgumentError) { Jev.choice("Pick", { only: "one" }) }
    end

    test "choice builder rejects more than 255 options" do
      too_many = (1..256).to_h { |i| ["opt#{i}", "desc"] }
      assert_raises(ArgumentError) { Jev.choice("Pick", too_many) }
    end

    test "choice builder stringifies symbol keys" do
      q = Jev.choice("Which team?", { billing: "Payments", technical: "Bugs" })
      assert_equal({ "billing" => "Payments", "technical" => "Bugs" }, q["criteria"])
    end

    # criteria values are EntryType — the structured form is how you pin down
    # a boundary Jev would otherwise read too literally, so it must survive
    # the builder intact rather than being flattened to a string.
    test "choice builder preserves structured option descriptions" do
      structured = {
        "billing" => {
          "what" => "Charges, invoices, refunds",
          "not_for" => "Order tracking",
          "examples" => ["I was charged twice"]
        },
        "technical" => "Bugs and outages"
      }
      q = Jev.choice("Which team?", structured)
      assert_equal structured, q["criteria"]
      assert_equal ["I was charged twice"], q["criteria"]["billing"]["examples"]
    end

    test "noul builder preserves structured criteria" do
      q = Jev.noul(
        "Requests credentials",
        true_means: { "what" => "Asks for a password", "examples" => ["Reply with your password"] },
        false_means: "No credential requested"
      )
      assert_equal ["Reply with your password"], q["criteria"]["true"]["examples"]
    end

    test "noul builder omits an unspecified branch rather than sending nil" do
      q = Jev.noul("Urgent?", true_means: "Time-sensitive")
      assert_equal({ "true" => "Time-sensitive" }, q["criteria"])
    end

    test "score builder preserves structured levels" do
      levels = [
        { "summary" => "One change, clearly stated" },
        { "summary" => "Several unrelated changes" }
      ]
      q = Jev.score("Scope", levels)
      assert_equal levels, q["criteria"]
    end

    test "score builder enforces the documented 2..10 level range" do
      assert_raises(ArgumentError) { Jev.score("Rate", ["only"]) }
      assert_raises(ArgumentError) { Jev.score("Rate", (1..11).map(&:to_s)) }
      assert_nothing_raised { Jev.score("Rate", %w[Low High]) }
    end

    # --- result accessors --------------------------------------------------

    test "reads each answer type" do
      r = result
      assert_in_delta 0.93, r.noul(:is_urgent), 0.001
      assert_equal "billing", r.choice(:route)
      assert_in_delta 1.05, r.score(:frustration), 0.001
      assert_in_delta 0.88, r.probabilities(:route)["billing"], 0.001
      assert_equal({ "input_tokens" => 296, "output_tokens" => 20 }, r.usage)
    end

    test "unknown question names return nil rather than raising" do
      r = result
      assert_nil r.noul(:nonexistent)
      assert_nil r.choice(:nonexistent)
      assert_nil r.confidence(:nonexistent)
      assert_equal({}, r.probabilities(:nonexistent))
    end

    test "a noul carries no separate confidence" do
      assert_nil result.confidence(:is_urgent)
    end

    test "resolves a score to its nearest named level" do
      # 1.05 rounds to level 1.
      assert_equal "Frustrated", result.level(:frustration)
      assert_nil result.level(:is_urgent)
    end

    # --- gates -------------------------------------------------------------

    test "confident_choice returns the choice only above threshold" do
      r = result
      assert_equal "billing", r.confident_choice(:route, 0.8)
      assert_nil r.confident_choice(:route, 0.9)
    end

    test "yes? compares against the probability" do
      r = result
      assert r.yes?(:is_urgent, 0.9)
      assert_not r.yes?(:is_urgent, 0.95)
    end

    test "an unanswered question is neither yes nor no" do
      r = result
      assert_not r.yes?(:nonexistent, 0.5)
      assert_not r.no?(:nonexistent, 0.5)
    end

    # This is the safety property the whole fail-soft design rests on: a failed
    # call must never read as consent at any threshold.
    test "an empty result never answers yes" do
      r = Jev::Result.empty(reason: "timeout")
      assert_not r.ok?
      assert_not r.yes?(:anything, 0.0)
      assert_nil r.confident_choice(:anything, 0.0)
      assert_equal "timeout", r.reason
    end

    # --- fail-soft ---------------------------------------------------------

    test "returns an empty result when no api key is configured" do
      Jev.stubs(:api_key).returns(nil)
      r = Jev.ask(state: "hello", questions: { q: Jev.noul("Urgent?") })
      assert_not r.ok?
      assert_equal "not configured", r.reason
    end

    test "returns an empty result when given no questions" do
      Jev.stubs(:api_key).returns("sk-test")
      r = Jev.ask(state: "hello", questions: {})
      assert_not r.ok?
      assert_equal "no questions", r.reason
    end

    test "a non-retryable http error fails soft without retrying" do
      Jev.stubs(:api_key).returns("sk-test")
      response = stub(status: 422, body: "bad request")
      HTTPX.stubs(:with).returns(stub(post: response))

      r = Jev.ask(state: "hello", questions: { q: Jev.noul("Urgent?") })
      assert_not r.ok?
      assert_equal "http 422", r.reason
    end

    test "a successful call parses into a usable result" do
      Jev.stubs(:api_key).returns("sk-test")
      response = stub(status: 200, body: PAYLOAD.to_json)
      HTTPX.stubs(:with).returns(stub(post: response))

      r = Jev.ask(state: "hello", questions: { q: Jev.noul("Urgent?") })
      assert r.ok?
      assert_equal "jev-1.13.0", r.model
      assert_equal "billing", r.choice(:route)
      assert_not_nil r.duration_ms
    end
  end
end
