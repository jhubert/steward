require 'yaml'
require 'singleton'

module Skills
  class Registry
    include Singleton

    Skill = Data.define(:name, :description, :path, :instructions)

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

        @skills[frontmatter['name']] = Skill.new(
          name: frontmatter['name'],
          description: frontmatter['description'] || '',
          path: dir.to_s,
          instructions: body || ''
        )
      end

      Rails.logger.info("[Skills] Loaded #{@skills.size} skills: #{@skills.keys.join(', ')}")
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
