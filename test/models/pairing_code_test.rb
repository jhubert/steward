require 'test_helper'

class PairingCodeTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
  end

  test 'generate creates a valid pairing code' do
    agent = agents(:jennifer)
    user = users(:alice)

    code = PairingCode.generate(agent: agent, created_by: user, label: "Bryan Alvis")

    assert code.persisted?
    assert_equal 6, code.code.length
    assert_equal "Bryan Alvis", code.label
    assert_equal agent, code.agent
    assert_equal user, code.created_by
    assert code.expires_at > Time.current
    assert_nil code.redeemed_at
    assert_nil code.redeemed_by
  end

  test 'find_valid returns valid unredeemed code' do
    code = pairing_codes(:valid_code)
    found = PairingCode.find_valid(agent: agents(:jennifer), code: "ABC123")

    assert_equal code, found
  end

  test 'find_valid is case-insensitive' do
    found = PairingCode.find_valid(agent: agents(:jennifer), code: "abc123")
    assert_equal pairing_codes(:valid_code), found
  end

  test 'find_valid returns nil for expired code' do
    found = PairingCode.find_valid(agent: agents(:jennifer), code: "EXP001")
    assert_nil found
  end

  test 'find_valid returns nil for redeemed code' do
    found = PairingCode.find_valid(agent: agents(:jennifer), code: "RDM001")
    assert_nil found
  end

  test 'find_valid returns nil for blank code' do
    assert_nil PairingCode.find_valid(agent: agents(:jennifer), code: nil)
    assert_nil PairingCode.find_valid(agent: agents(:jennifer), code: "")
  end

  test 'find_valid returns nil for wrong agent' do
    found = PairingCode.find_valid(agent: agents(:steward), code: "ABC123")
    assert_nil found
  end

  test 'redeem sets redeemed_by and redeemed_at' do
    code = pairing_codes(:valid_code)
    user = users(:bob)

    code.redeem!(user)
    code.reload

    assert_equal user, code.redeemed_by
    assert code.redeemed_at.present?
    assert code.redeemed?
  end

  test 'expired? returns true for expired codes' do
    assert pairing_codes(:expired_code).expired?
  end

  test 'expired? returns false for valid codes' do
    assert_not pairing_codes(:valid_code).expired?
  end

  test 'redeemed? returns true for redeemed codes' do
    assert pairing_codes(:redeemed_code).redeemed?
  end

  test 'redeemed? returns false for unredeemed codes' do
    assert_not pairing_codes(:valid_code).redeemed?
  end
end
