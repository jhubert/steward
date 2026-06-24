require 'test_helper'

# Focused tests for the prepare-first pipeline on email tools. The prepare
# methods are side-effect-free: they validate + resolve recipients into a
# canonical payload that the gate (and the resolve job) consume.
class ProcessMessageJobEmailPrepareTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @agent = agents(:jennifer)
    @conversation = conversations(:bob_jennifer)
    @job = ProcessMessageJob.new
  end

  # --- prepare_send_email ---

  test "prepare_send_email returns ok payload + recipients when valid" do
    prep = @job.send(:prepare_send_email,
      { "to" => "Alice <alice@example.com>", "cc" => "bob@example.com", "subject" => "Hi", "body" => "Hello" },
      @agent, @conversation
    )
    assert prep[:ok]
    assert_equal "Hi", prep[:payload]["subject"]
    assert_equal ["alice@example.com", "bob@example.com"], prep[:recipients]
  end

  test "prepare_send_email fails without email_handle" do
    @agent.update!(settings: @agent.settings.except("email_handle"))
    prep = @job.send(:prepare_send_email,
      { "to" => "x@example.com", "subject" => "Hi", "body" => "Hello" },
      @agent, @conversation
    )
    refute prep[:ok]
    assert_includes prep[:error], "email handle"
  end

  test "prepare_send_email fails on missing required fields" do
    prep = @job.send(:prepare_send_email,
      { "to" => "x@example.com", "subject" => "Hi", "body" => "" },
      @agent, @conversation
    )
    refute prep[:ok]
    assert_includes prep[:error], "are all required"
  end

  # --- prepare_gmail_new_thread ---

  test "prepare_gmail_new_thread runs Allowlist and resolves recipients" do
    @agent.update!(settings: @agent.settings.merge("gog_email" => "jennifer@boardwise.co"))
    @agent.stubs(:own_gog_env).returns({ "GOG_ACCOUNT" => "jennifer@boardwise.co" })

    allow_result = Struct.new(:ok?, :blocked).new(true, [])
    Tools::EmailGate::Allowlist.any_instance.expects(:call).returns(allow_result)

    prep = @job.send(:prepare_gmail_new_thread,
      { "to" => "alice@example.com", "subject" => "Hi", "body" => "Hello" },
      @agent, @conversation
    )
    assert prep[:ok]
    assert_equal ["alice@example.com"], prep[:recipients]
    assert_equal "alice@example.com", prep[:payload]["to"]
  end

  test "prepare_gmail_new_thread fails when Allowlist rejects" do
    @agent.stubs(:own_gog_env).returns({ "GOG_ACCOUNT" => "jennifer@boardwise.co" })
    allow_result = Struct.new(:ok?, :blocked).new(false, ["stranger@unknown.com"])
    Tools::EmailGate::Allowlist.any_instance.expects(:call).returns(allow_result)

    prep = @job.send(:prepare_gmail_new_thread,
      { "to" => "stranger@unknown.com", "subject" => "Hi", "body" => "Hello" },
      @agent, @conversation
    )
    refute prep[:ok]
    assert_includes prep[:error], "not on allowlist"
  end

  # --- prepare_gmail_reply ---

  test "prepare_gmail_reply derives subject/to/cc from the inbound thread and runs QuoteBack" do
    @agent.stubs(:own_gog_env).returns({ "GOG_ACCOUNT" => "jennifer@boardwise.co" })
    ProcessMessageJob.any_instance.stubs(:fetch_latest_inbound).returns(
      message: { foo: 1 },
      body: "Original message text — please reply with a verbatim quote.",
      subject: "Heliostar request",
      from_email: "alice@example.com",
      cc: "bob@example.com"
    )
    qb_ok = Struct.new(:ok?, :reason).new(true, nil)
    Tools::EmailGate::QuoteBack.any_instance.expects(:call).returns(qb_ok)

    prep = @job.send(:prepare_gmail_reply,
      { "thread_id" => "T1", "body" => "Quote: please reply with a verbatim quote." },
      @agent, @conversation
    )

    assert prep[:ok]
    assert_equal "Re: Heliostar request", prep[:payload]["subject"]
    assert_equal "alice@example.com", prep[:payload]["to"]
    assert_equal "bob@example.com", prep[:payload]["cc"]
    assert_equal ["alice@example.com", "bob@example.com"], prep[:recipients]
  end

  test "prepare_gmail_reply fails when QuoteBack rejects (no human ping needed)" do
    @agent.stubs(:own_gog_env).returns({ "GOG_ACCOUNT" => "jennifer@boardwise.co" })
    ProcessMessageJob.any_instance.stubs(:fetch_latest_inbound).returns(
      message: { foo: 1 }, body: "Original text", subject: "X", from_email: "alice@example.com", cc: nil
    )
    qb_fail = Struct.new(:ok?, :reason).new(false, "no literal substring of 15+ characters found")
    Tools::EmailGate::QuoteBack.any_instance.expects(:call).returns(qb_fail)

    prep = @job.send(:prepare_gmail_reply,
      { "thread_id" => "T1", "body" => "Reply without a quote." },
      @agent, @conversation
    )
    refute prep[:ok]
    assert_includes prep[:error], "Reply rejected"
    assert_includes prep[:error], "no literal substring"
  end

  test "prepare_gmail_reply auto-approves when the inbound is from a principal" do
    # This is the bug we set out to fix: a reply to a thread Jennifer didn't
    # initiate should auto-approve when the resolved recipients are principals.
    @agent.stubs(:own_gog_env).returns({ "GOG_ACCOUNT" => "jennifer@boardwise.co" })
    ProcessMessageJob.any_instance.stubs(:fetch_latest_inbound).returns(
      message: {}, body: "Hi Jenn, please send research on Heliostar.",
      subject: "Heliostar", from_email: "alice@example.com", cc: nil
    )
    qb_ok = Struct.new(:ok?, :reason).new(true, nil)
    Tools::EmailGate::QuoteBack.any_instance.expects(:call).returns(qb_ok)

    prep = @job.send(:prepare_gmail_reply,
      { "thread_id" => "T_NEW", "body" => "Re: please send research on Heliostar — attached." },
      @agent, @conversation
    )
    assert prep[:ok]
    assert @agent.auto_approve_recipients?(prep[:recipients]),
      "Expected resolved principal-only recipients to auto-approve"
  end
end
