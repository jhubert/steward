require 'test_helper'

class WorkspaceTest < ActiveSupport::TestCase
  test 'requires name' do
    workspace = Workspace.new(slug: 'test')
    assert_not workspace.valid?
    assert_includes workspace.errors[:name], "can't be blank"
  end

  test 'requires unique slug' do
    workspace = Workspace.new(name: 'Duplicate', slug: workspaces(:default).slug)
    assert_not workspace.valid?
    assert_includes workspace.errors[:slug], 'has already been taken'
  end
end
