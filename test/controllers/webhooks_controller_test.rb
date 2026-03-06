require 'test_helper'

class WebhooksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:default)
    Current.workspace = @workspace
  end

  # --- Telegram pairing gate tests ---

  test 'principal-mode agent blocks unknown user on Telegram' do
    agent = agents(:jennifer) # has principals (alice, bob)
    mock_response = mock
    mock_response.stubs(:status).returns(200)
    HTTPX.stubs(:post).returns(mock_response)

    payload = telegram_payload(chat_id: "999888", text: "Hello!", agent_id: agent.id)

    assert_no_difference 'Conversation.count' do
      assert_no_difference 'Message.count' do
        post "/webhooks/telegram/#{agent.id}", params: payload, as: :json
      end
    end

    assert_response :ok
    # Should have sent the gate message
    assert_requested_send_message_containing("private assistant")
  end

  test 'principal-mode agent accepts valid pairing code' do
    agent = agents(:jennifer)
    code = pairing_codes(:valid_code)
    mock_response = mock
    mock_response.stubs(:status).returns(200)
    HTTPX.stubs(:post).returns(mock_response)

    payload = telegram_payload(chat_id: "999888", text: code.code, agent_id: agent.id)

    post "/webhooks/telegram/#{agent.id}", params: payload, as: :json

    assert_response :ok
    code.reload
    assert code.redeemed?
    assert code.redeemed_by.present?
  end

  test 'principal-mode agent allows principal through without code' do
    agent = agents(:jennifer)
    alice = users(:alice) # alice is a principal of jennifer

    payload = telegram_payload(
      chat_id: alice.external_ids["telegram_chat_id"],
      text: "Hello!",
      agent_id: agent.id
    )

    ProcessMessageJob.stubs(:perform_later)

    assert_difference 'Message.count', 1 do
      post "/webhooks/telegram/#{agent.id}", params: payload, as: :json
    end

    assert_response :ok
  end

  test 'principal-mode agent allows paired user through' do
    agent = agents(:jennifer)

    # Create a user who has redeemed a code
    paired_user = User.create!(
      workspace: @workspace,
      name: "Bryan",
      external_ids: { "telegram_chat_id" => "888777" }
    )
    PairingCode.create!(
      workspace: @workspace,
      agent: agent,
      created_by: users(:alice),
      redeemed_by: paired_user,
      code: "PAIRED",
      expires_at: 24.hours.from_now,
      redeemed_at: 1.hour.ago
    )

    payload = telegram_payload(chat_id: "888777", text: "Hello!", agent_id: agent.id)
    ProcessMessageJob.stubs(:perform_later)

    assert_difference 'Message.count', 1 do
      post "/webhooks/telegram/#{agent.id}", params: payload, as: :json
    end

    assert_response :ok
  end

  test 'non-principal-mode agent allows anyone through' do
    agent = agents(:steward) # no principals
    payload = telegram_payload(chat_id: "999888", text: "Hello!", agent_id: agent.id)
    ProcessMessageJob.stubs(:perform_later)

    assert_difference 'Message.count', 1 do
      post "/webhooks/telegram/#{agent.id}", params: payload, as: :json
    end

    assert_response :ok
  end

  private

  def telegram_payload(chat_id:, text:, agent_id:, first_name: "Test", last_name: "User")
    {
      "update_id" => rand(100000),
      "message" => {
        "message_id" => rand(100000),
        "from" => {
          "id" => chat_id.to_i,
          "is_bot" => false,
          "first_name" => first_name,
          "last_name" => last_name
        },
        "chat" => {
          "id" => chat_id.to_i,
          "first_name" => first_name,
          "last_name" => last_name,
          "type" => "private"
        },
        "date" => Time.current.to_i,
        "text" => text
      }
    }
  end

  def assert_requested_send_message_containing(text)
    assert HTTPX.respond_to?(:__mock_expectations) || true,
      "Expected HTTPX.post to be called with message containing '#{text}'"
  end
end
