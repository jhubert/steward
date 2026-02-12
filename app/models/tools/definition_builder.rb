module Tools
  class DefinitionBuilder
    def initialize(agent:)
      @agent = agent
    end

    def call
      tools = @agent.enabled_tools.map(&:to_anthropic_tool)
      tools.presence
    end
  end
end
