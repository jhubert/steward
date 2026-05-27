require 'test_helper'

class EpisodeTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @conv = conversations(:alice_jennifer)
  end

  test 'requires channel, started_at, ended_at' do
    ep = Episode.new(
      workspace: workspaces(:default),
      user: users(:alice),
      agent: agents(:jennifer),
      conversation: @conv
    )
    assert_not ep.valid?
    assert ep.errors[:channel].any?
    assert ep.errors[:started_at].any?
    assert ep.errors[:ended_at].any?
  end

  test 'for_user_agent scope filters by user+agent' do
    other = Episode.create!(
      workspace: workspaces(:default),
      user: users(:bob),
      agent: agents(:jennifer),
      conversation: conversations(:bob_jennifer),
      channel: 'telegram',
      title: 'Bob episode',
      summary: 'About Bob',
      started_at: 1.hour.ago,
      ended_at: 30.minutes.ago
    )
    own = Episode.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      agent: agents(:jennifer),
      conversation: @conv,
      channel: 'telegram',
      title: 'Alice episode',
      summary: 'About Alice',
      started_at: 1.hour.ago,
      ended_at: 30.minutes.ago
    )

    scoped = Episode.for_user_agent(users(:alice), agents(:jennifer))
    assert_includes scoped, own
    assert_not_includes scoped, other
  end

  test 'message_range returns conversation messages bounded by first/last' do
    m1 = @conv.messages.create!(role: 'user', content: 'range message 1')
    m1.update_column(:created_at, 5.minutes.ago)
    m2 = @conv.messages.create!(role: 'assistant', content: 'range message 2')
    m2.update_column(:created_at, 4.minutes.ago)
    m3 = @conv.messages.create!(role: 'user', content: 'range message 3')
    m3.update_column(:created_at, 3.minutes.ago)

    ep = Episode.create!(
      workspace: workspaces(:default),
      user: users(:alice),
      agent: agents(:jennifer),
      conversation: @conv,
      channel: 'telegram',
      title: 'Range test',
      summary: 'Range test',
      first_message_id: m1.id,
      last_message_id: m3.id,
      started_at: m1.created_at,
      ended_at: m3.created_at
    )

    ids = ep.message_range.pluck(:id)
    assert_includes ids, m1.id
    assert_includes ids, m2.id
    assert_includes ids, m3.id
  end
end
