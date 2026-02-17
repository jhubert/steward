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

  test 'loads tool definitions from tools.yml' do
    registry = Skills::Registry.instance
    skill = registry.find('gog')

    assert_not_nil skill
    assert skill.tool_definitions.any?, 'Expected gog skill to have tool definitions'

    tool = skill.tool_definitions.first
    assert_equal 'gog', tool[:name]
    assert tool[:description].present?
    assert tool[:input_schema].present?
    assert tool[:command_template].present?
    assert_equal 60, tool[:timeout_seconds]
  end

  test 'skill without tools.yml has empty tool_definitions' do
    registry = Skills::Registry.instance
    skill = registry.find('example')

    assert_not_nil skill
    assert_equal [], skill.tool_definitions
  end

  test 'multi-tool skill loads all tools' do
    registry = Skills::Registry.instance
    skill = registry.find('pdf')

    assert_not_nil skill
    assert_equal 3, skill.tool_definitions.size

    tool_names = skill.tool_definitions.map { |d| d[:name] }
    assert_includes tool_names, 'pdf_extract'
    assert_includes tool_names, 'pdf_coords'
    assert_includes tool_names, 'pdf_fill'
  end

  test 'tools_for returns tool definitions for a skill' do
    registry = Skills::Registry.instance
    tools = registry.tools_for('github')

    assert_equal 1, tools.size
    assert_equal 'github', tools.first[:name]
  end

  test 'tools_for returns empty array for unknown skill' do
    registry = Skills::Registry.instance
    assert_equal [], registry.tools_for('nonexistent')
  end

  test 'working_directory defaults to skill path' do
    registry = Skills::Registry.instance
    skill = registry.find('gog')
    tool = skill.tool_definitions.first

    assert_equal skill.path, tool[:working_directory]
  end

  test 'auto-reloads when a new skill is created on disk' do
    registry = Skills::Registry.instance

    # Verify the skill does not exist yet
    assert_nil registry.find('test-auto-reload')

    # Create a new skill on disk
    skill_dir = Rails.root.join('skills', 'test-auto-reload')
    FileUtils.mkdir_p(skill_dir)
    File.write(skill_dir.join('SKILL.md'), <<~MD)
      ---
      name: test-auto-reload
      description: A test skill for auto-reload.
      ---

      # Test Auto-Reload

      This skill tests auto-reload detection.
    MD

    # Touch the skills directory to update mtime
    FileUtils.touch(Rails.root.join('skills'))

    # find should auto-reload and discover the new skill
    skill = registry.find('test-auto-reload')
    assert_not_nil skill, 'Expected auto-reload to discover the new skill'
    assert_equal 'test-auto-reload', skill.name
    assert_equal 'A test skill for auto-reload.', skill.description
  ensure
    FileUtils.rm_rf(skill_dir) if skill_dir&.exist?
    registry.reload!
  end

  test 'auto-reloads when a SKILL.md is modified' do
    registry = Skills::Registry.instance

    # Create a skill
    skill_dir = Rails.root.join('skills', 'test-modify-reload')
    FileUtils.mkdir_p(skill_dir)
    File.write(skill_dir.join('SKILL.md'), <<~MD)
      ---
      name: test-modify-reload
      description: Original description.
      ---

      # Original
    MD
    FileUtils.touch(Rails.root.join('skills'))
    registry.reload!

    skill = registry.find('test-modify-reload')
    assert_equal 'Original description.', skill.description

    # Modify the SKILL.md
    sleep 0.1 # ensure mtime changes
    File.write(skill_dir.join('SKILL.md'), <<~MD)
      ---
      name: test-modify-reload
      description: Updated description.
      ---

      # Updated
    MD

    # find should pick up the change
    skill = registry.find('test-modify-reload')
    assert_equal 'Updated description.', skill.description
  ensure
    FileUtils.rm_rf(skill_dir) if skill_dir&.exist?
    registry.reload!
  end
end
