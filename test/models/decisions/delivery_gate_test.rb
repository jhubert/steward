require "test_helper"

module Decisions
  class DeliveryGateTest < ActiveSupport::TestCase
    setup do
      as_workspace(:default)
      @agent = agents(:jennifer)
      @conversation = conversations(:alice_jennifer)
    end

    def gate(reply_text: "Digest sent.", source: nil)
      reply = Message.new(content: reply_text, role: "assistant")
      DeliveryGate.new(agent: @agent, conversation: @conversation,
                       reply: reply, source_message: source)
    end

    def stub_signals(**vals)
      answers = vals.transform_keys(&:to_s).transform_values { |v| { "type" => "noul", "noul" => v } }
      Jev.stubs(:configured?).returns(true)
      Jev.stubs(:ask).returns(Jev::Result.new(payload: { "answers" => answers, "usage" => { "input_tokens" => 100 } }))
    end

    # --- mode resolution ---------------------------------------------------

    test "defaults to off and ignores unknown modes" do
      assert_equal DeliveryGate::OFF, DeliveryGate.mode_for(Agent.new(settings: {}))
      assert_equal DeliveryGate::OFF, DeliveryGate.mode_for(Agent.new(settings: { "delivery_gate" => "yes please" }))
      assert_equal DeliveryGate::SHADOW, DeliveryGate.mode_for(Agent.new(settings: { "delivery_gate" => "shadow" }))
    end

    # --- scope -------------------------------------------------------------
    # The gate must never be able to silence a reply to a human.

    test "applies only to agent-triggered messages in background conversations" do
      bg = Conversation.new(channel: "background")
      tg = Conversation.new(channel: "telegram")
      triggered = Message.new(metadata: { "source" => "trigger" })
      typed = Message.new(metadata: {})

      assert DeliveryGate.applicable?(bg, triggered)
      assert_not DeliveryGate.applicable?(bg, typed), "a human typing into a background thread must not be gated"
      assert_not DeliveryGate.applicable?(tg, triggered)
      assert_not DeliveryGate.applicable?(bg, nil)
      assert_not DeliveryGate.applicable?(nil, triggered)
    end

    # --- fail open ---------------------------------------------------------

    test "delivers when the gate is off without calling jev" do
      @agent.settings = @agent.settings.merge("delivery_gate" => "off")
      Jev.expects(:ask).never
      d = gate.call
      assert d.deliver
      assert_equal "gate off", d.reason
    end

    test "delivers when jev is not configured" do
      @agent.settings = @agent.settings.merge("delivery_gate" => "enforcing")
      Jev.stubs(:configured?).returns(false)
      assert gate.call.deliver
    end

    test "delivers when jev fails" do
      @agent.settings = @agent.settings.merge("delivery_gate" => "enforcing")
      Jev.stubs(:configured?).returns(true)
      Jev.stubs(:ask).returns(Jev::Result.empty(reason: "timeout"))
      d = gate.call
      assert d.deliver, "a failed decision must never suppress a message"
      assert_match(/timeout/, d.reason)
    end

    test "delivers an empty reply rather than reasoning about it" do
      @agent.settings = @agent.settings.merge("delivery_gate" => "enforcing")
      Jev.expects(:ask).never
      assert gate(reply_text: "").call.deliver
    end

    # --- explicit declaration ---------------------------------------------

    test "stay_silent short-circuits without spending a call" do
      @agent.settings = @agent.settings.merge("delivery_gate" => "enforcing")
      Jev.expects(:ask).never
      d = gate.call(agent_declared_silent: true)
      assert_not d.deliver
      assert_equal "agent called stay_silent", d.reason
    end

    # --- policy ordering ---------------------------------------------------

    test "self-declared silence outranks a needs-recipient signal" do
      @agent.settings = @agent.settings.merge("delivery_gate" => "enforcing")
      stub_signals(reports_event: 0.81, needs_recipient: 0.52, merely_confirms: 0.15,
                   standing_request: 0.16, self_declared_silent: 0.92)
      d = gate.call
      assert_not d.deliver
      assert_equal "agent said not to notify", d.reason
    end

    test "a standing request beats the nothing-happened heuristics" do
      @agent.settings = @agent.settings.merge("delivery_gate" => "enforcing")
      stub_signals(reports_event: 0.10, needs_recipient: 0.20, merely_confirms: 0.90,
                   standing_request: 0.85, self_declared_silent: 0.10)
      d = gate.call
      assert d.deliver
      assert_equal "standing request", d.reason
    end

    test "anything the recipient must act on is delivered" do
      @agent.settings = @agent.settings.merge("delivery_gate" => "enforcing")
      stub_signals(reports_event: 0.30, needs_recipient: 0.75, merely_confirms: 0.85,
                   standing_request: 0.10, self_declared_silent: 0.10)
      assert_equal "needs recipient", gate.call.reason
    end

    test "holds a routine confirmation with no event" do
      @agent.settings = @agent.settings.merge("delivery_gate" => "enforcing")
      stub_signals(reports_event: 0.18, needs_recipient: 0.13, merely_confirms: 0.89,
                   standing_request: 0.21, self_declared_silent: 0.10)
      d = gate.call
      assert_not d.deliver
      assert_equal "routine confirmation only", d.reason
    end

    test "holds when nothing happened at all" do
      @agent.settings = @agent.settings.merge("delivery_gate" => "enforcing")
      stub_signals(reports_event: 0.13, needs_recipient: 0.17, merely_confirms: 0.40,
                   standing_request: 0.28, self_declared_silent: 0.10)
      assert_equal "no event reported", gate.call.reason
    end

    test "ambiguous signals default to sending" do
      @agent.settings = @agent.settings.merge("delivery_gate" => "enforcing")
      stub_signals(reports_event: 0.60, needs_recipient: 0.40, merely_confirms: 0.50,
                   standing_request: 0.30, self_declared_silent: 0.20)
      d = gate.call
      assert d.deliver
      assert_equal "default send", d.reason
    end

    test "records the raw signals for review" do
      @agent.settings = @agent.settings.merge("delivery_gate" => "shadow")
      stub_signals(reports_event: 0.13, needs_recipient: 0.17, merely_confirms: 0.89,
                   standing_request: 0.21, self_declared_silent: 0.10)
      d = gate.call
      assert_in_delta 0.89, d.signals["merely_confirms"], 0.001
      assert_equal DeliveryGate::SHADOW, d.mode
      assert_equal 100, d.input_tokens
    end

    # --- state -------------------------------------------------------------

    test "extracts the task description from a scheduled trigger" do
      @agent.settings = @agent.settings.merge("delivery_gate" => "enforcing")
      captured = nil
      Jev.stubs(:configured?).returns(true)
      Jev.stubs(:ask).with { |kw| captured = kw[:state]; true }
         .returns(Jev::Result.empty(reason: "x"))

      source = Message.new(content: "[Scheduled Task: Check for new unread email in Gmail]\n[Tool: check_email]\nYou have 1 unread")
      gate(source: source).call

      assert_equal "Check for new unread email in Gmail", captured["task_description"]
      assert_equal "Digest sent.", captured["draft_message"]
    end
  end
end
