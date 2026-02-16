require 'yaml'
require 'singleton'

module Skills
  class Registry
    include Singleton

    Skill = Data.define(:name, :description, :path, :instructions, :tool_definitions)

    def initialize
      @skills = {}
      load_skills
    end

    def reload!
      @skills = {}
      load_skills
    end

    def all
      @skills.values
    end

    def find(name)
      @skills[name]
    end

    # Returns skills whose instructions should be included in the prompt.
    # For now, returns all skills. The Activator will filter in the future.
    def active_skills_for(conversation)
      # Phase 1: no activation logic, return empty.
      # Skills are opt-in via conversation metadata or explicit commands.
      skill_names = conversation.metadata&.dig('active_skills') || []
      skill_names.filter_map { |name| @skills[name] }
    end

    # Metadata-only catalog for system prompt (name + description, lightweight).
    def catalog
      @skills.map do |name, skill|
        { name: name, description: skill.description }
      end
    end

    # Returns tool definitions for a specific skill.
    def tools_for(skill_name)
      @skills.dig(skill_name)&.tool_definitions || []
    end

    private

    def load_skills
      skills_dir = Rails.root.join('skills')
      return unless skills_dir.exist?

      skills_dir.children.select(&:directory?).each do |dir|
        skill_md = dir.join('SKILL.md')
        next unless skill_md.exist?

        content = skill_md.read
        frontmatter, body = parse_skill_md(content)
        next unless frontmatter && frontmatter['name']

        tool_defs = load_tool_definitions(dir)

        @skills[frontmatter['name']] = Skill.new(
          name: frontmatter['name'],
          description: frontmatter['description'] || '',
          path: dir.to_s,
          instructions: body || '',
          tool_definitions: tool_defs
        )
      end

      Rails.logger.info("[Skills] Loaded #{@skills.size} skills: #{@skills.keys.join(', ')}")
    end

    def load_tool_definitions(dir)
      tools_yml = dir.join('tools.yml')
      return [] unless tools_yml.exist?

      data = YAML.safe_load(tools_yml.read)
      return [] unless data.is_a?(Hash) && data['tools'].is_a?(Array)

      data['tools'].map do |tool|
        {
          name: tool['name'],
          description: tool['description'],
          input_schema: tool['input_schema'],
          command_template: tool['command_template'],
          working_directory: tool['working_directory'] || dir.to_s,
          timeout_seconds: tool['timeout_seconds'] || 30
        }
      end
    end

    def parse_skill_md(content)
      if content.start_with?('---')
        parts = content.split('---', 3)
        if parts.length >= 3
          frontmatter = YAML.safe_load(parts[1])
          body = parts[2].strip
          return [frontmatter, body]
        end
      end
      [nil, nil]
    end
  end
end
