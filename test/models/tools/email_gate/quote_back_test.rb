require "test_helper"

class Tools::EmailGate::QuoteBackTest < ActiveSupport::TestCase
  test "passes when draft contains a meaningful substring from inbound" do
    inbound = "Hi Jennifer, is this site protected from a cybersecurity perspective? And can you delete one of my duplicate boards?"
    draft = "Great question — yes, the site is protected from a cybersecurity perspective. Regarding the duplicate boards..."

    result = Tools::EmailGate::QuoteBack.new.call(inbound_body: inbound, draft_body: draft)
    assert result.ok?, "expected pass but got: #{result.reason}"
  end

  test "fails when draft answers unrelated questions (the Tom fabrication case)" do
    inbound = <<~EMAIL
      HI Jennifer

      Hope all is well, this all looks reasonably intuitive. I just have 2 questions:

      1. Is this site and the documents loaded onto it protected from a cyber security perspective?
      2. I seem to have created 2 Boards accidentally, would it be possible to delete one on the backend?

      Thanks
      Tom
    EMAIL

    draft = <<~REPLY
      Hi Tom,

      Great questions — glad you're getting familiar with things. Here's a quick rundown:

      1. Publishing documents: documents stay in draft until you publish them.
      2. Organizing by meeting or committee: documents are attached to specific meetings.
      3. Committee-level permissions: when you create a committee and assign members to it...

      Best,
      Jennifer
    REPLY

    result = Tools::EmailGate::QuoteBack.new.call(inbound_body: inbound, draft_body: draft)
    refute result.ok?, "expected fail but passed"
    assert_match(/no literal substring/, result.reason)
  end

  test "fails when draft body is empty" do
    result = Tools::EmailGate::QuoteBack.new.call(inbound_body: "hello world", draft_body: "")
    refute result.ok?
    assert_match(/draft reply is empty/, result.reason)
  end

  test "fails when inbound body is empty" do
    result = Tools::EmailGate::QuoteBack.new.call(inbound_body: "", draft_body: "hello")
    refute result.ok?
    assert_match(/inbound message is empty/, result.reason)
  end

  test "requires multi-word match — single-word overlap (URL only) fails" do
    inbound = "https://app.boardwise.co/settings is where you go."
    # Draft only shares the URL (one word); no multi-word phrase in common.
    draft = "Try https://app.boardwise.co/settings in your browser."

    result = Tools::EmailGate::QuoteBack.new(min_words: 3).call(inbound_body: inbound, draft_body: draft)
    refute result.ok?, "expected URL-only match to fail, got: #{result.reason}"
  end

  test "case-insensitive matching" do
    inbound = "CAN YOU CONFIRM THE DEADLINE IS FRIDAY?"
    draft = "Yes, I can confirm the deadline is Friday. It's locked in."

    result = Tools::EmailGate::QuoteBack.new.call(inbound_body: inbound, draft_body: draft)
    assert result.ok?
  end

  test "whitespace-insensitive matching" do
    inbound = "Please\n\nconfirm\nthe   deadline  is Friday"
    draft = "Yes, confirm the deadline is Friday."

    result = Tools::EmailGate::QuoteBack.new.call(inbound_body: inbound, draft_body: draft)
    assert result.ok?
  end
end
