module Tools
  class DefinitionBuilder
    BUILTIN_TOOLS = [
      {
        name: "save_note",
        description: "Save a note to your persistent scratchpad. Use this to remember important information across messages — intermediate results, state from tool calls, plans, decisions, or anything you'll need later. Notes persist until the conversation is compacted.",
        input_schema: {
          "type" => "object",
          "properties" => {
            "content" => { "type" => "string", "description" => "The note to save" }
          },
          "required" => ["content"]
        }
      },
      {
        name: "read_notes",
        description: "Read all notes from your persistent scratchpad. Use this to recall information you previously saved with save_note.",
        input_schema: {
          "type" => "object",
          "properties" => {}
        }
      }
    ].freeze

    def initialize(agent:)
      @agent = agent
    end

    def call
      tools = @agent.enabled_tools.map(&:to_anthropic_tool)
      tools.concat(BUILTIN_TOOLS)
      tools.presence
    end
  end
end
