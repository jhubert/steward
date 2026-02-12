require 'test_helper'

class Skills::RegistryTest < ActiveSupport::TestCase
  test 'loads skills from filesystem' do
    registry = Skills::Registry.instance
    assert registry.all.any?, 'Expected at least one skill to be loaded'
  end

  test 'finds skill by name' do
    registry = Skills::Registry.instance
    skill = registry.find('example')

    assert_not_nil skill
    assert_equal 'example', skill.name
    assert skill.description.present?
    assert skill.instructions.present?
  end

  test 'catalog returns lightweight metadata' do
    catalog = Skills::Registry.instance.catalog
    assert_instance_of Array, catalog
    assert catalog.first.key?(:name)
    assert catalog.first.key?(:description)
  end
end
