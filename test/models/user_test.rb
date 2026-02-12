require 'test_helper'

class UserTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
  end

  test 'find_by_external finds user by telegram chat id' do
    user = User.find_by_external('telegram_chat_id', '111111')
    assert_equal users(:alice), user
  end

  test 'find_by_external returns nil for unknown id' do
    user = User.find_by_external('telegram_chat_id', '999999')
    assert_nil user
  end

  test 'workspace scoping isolates users' do
    as_workspace(:default)
    default_users = User.all.to_a

    as_workspace(:other)
    other_users = User.all.to_a

    assert_includes default_users, users(:alice)
    assert_not_includes default_users, users(:eve)
    assert_includes other_users, users(:eve)
    assert_not_includes other_users, users(:alice)
  end
end
