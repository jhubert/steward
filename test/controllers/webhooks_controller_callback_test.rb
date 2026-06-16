require 'test_helper'

class WebhooksControllerCallbackTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:default)
    Current.workspace = @workspace
    @agent = agents(:jennifer)
    @approver = users(:alice) # has telegram_chat_id "111111"

    @pending = PendingAction.create!(
      workspace: @workspace,
      agent: @agent,
      conversation: conversations(:alice_jennifer),
      approver_user: @approver,
      tool_name: "send_email",
      tool_input: { "to" => "x@example.com", "subject" => "Hi", "body" => "Hello" },
      approval_chat_id: "111111",
      approval_message_id: 42
    )

    # Silence outgoing Telegram acks
    Adapters::Telegram.any_instance.stubs(:answer_callback_query).returns(true)
  end

  test "approve callback from the approver enqueues ResolvePendingActionJob" do
    payload = callback_payload(
      pending: @pending,
      decision: "approve",
      from_chat_id: @approver.external_ids["telegram_chat_id"]
    )

    assert_enqueued_with(job: ResolvePendingActionJob, args: [@pending.id, { decision: "approve" }]) do
      post "/webhooks/telegram/#{@agent.id}", params: payload, as: :json
    end

    assert_response :ok
  end

  test "callback from a non-approver is ignored" do
    payload = callback_payload(
      pending: @pending,
      decision: "approve",
      from_chat_id: "999999" # not the approver
    )

    assert_no_enqueued_jobs only: ResolvePendingActionJob do
      post "/webhooks/telegram/#{@agent.id}", params: payload, as: :json
    end

    assert_response :ok
  end

  test "garbage callback_data is acknowledged and ignored" do
    payload = base_callback_envelope(callback_data: "garbage")
    assert_no_enqueued_jobs only: ResolvePendingActionJob do
      post "/webhooks/telegram/#{@agent.id}", params: payload, as: :json
    end
    assert_response :ok
  end

  test "already-resolved pending action is not re-enqueued" do
    @pending.update!(status: "approved", resolved_at: 1.minute.ago)
    payload = callback_payload(
      pending: @pending,
      decision: "approve",
      from_chat_id: @approver.external_ids["telegram_chat_id"]
    )

    assert_no_enqueued_jobs only: ResolvePendingActionJob do
      post "/webhooks/telegram/#{@agent.id}", params: payload, as: :json
    end
  end

  private

  def callback_payload(pending:, decision:, from_chat_id:)
    base_callback_envelope(
      callback_data: pending.callback_data(decision),
      from_chat_id: from_chat_id
    )
  end

  def base_callback_envelope(callback_data:, from_chat_id: "111111")
    {
      "update_id" => rand(100000),
      "callback_query" => {
        "id" => SecureRandom.hex(8),
        "from" => { "id" => from_chat_id.to_i, "first_name" => "Alice" },
        "data" => callback_data,
        "message" => {
          "message_id" => 42,
          "chat" => { "id" => from_chat_id.to_i, "type" => "private" }
        }
      }
    }
  end
end
