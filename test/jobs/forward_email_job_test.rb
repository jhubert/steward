require "test_helper"

class ForwardEmailJobTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @agent = agents(:jennifer)
  end

  test "forwards email to routed principal" do
    # Stub the router to return alice's principal record
    principal = agent_principals(:jennifer_alice)
    Email::PrincipalRouter.any_instance.stubs(:route).returns(principal)

    # Expect adapter to send the forwarding email
    Adapters::Email.any_instance.expects(:send_new_email).with(
      from_handle: "jennifer",
      to: "alice@example.com",
      subject: "Fwd: Invoice #123",
      body: regexp_matches(/Vendor.*vendor@example.com.*Invoice #123.*Please pay/m)
    ).returns("msg-id-123")

    ForwardEmailJob.perform_now(
      @agent.id,
      sender_name: "Vendor",
      sender_email: "vendor@example.com",
      subject: "Invoice #123",
      body: "Please pay"
    )
  end

  test "does nothing when no principal has email contact" do
    Email::PrincipalRouter.any_instance.stubs(:route).returns(nil)
    Adapters::Email.any_instance.expects(:send_new_email).never

    ForwardEmailJob.perform_now(
      @agent.id,
      sender_name: "Vendor",
      sender_email: "vendor@example.com",
      subject: "Hello",
      body: "Hi"
    )
  end

  test "does nothing when agent has no email handle" do
    @agent.update!(settings: @agent.settings.merge("email_handle" => nil))

    Email::PrincipalRouter.any_instance.expects(:route).never
    Adapters::Email.any_instance.expects(:send_new_email).never

    ForwardEmailJob.perform_now(
      @agent.id,
      sender_name: "Vendor",
      sender_email: "vendor@example.com",
      subject: "Hello",
      body: "Hi"
    )
  end

  test "discards when agent not found" do
    assert_nothing_raised do
      ForwardEmailJob.perform_now(
        999999,
        sender_name: "Vendor",
        sender_email: "vendor@example.com",
        subject: "Hello",
        body: "Hi"
      )
    end
  end
end
