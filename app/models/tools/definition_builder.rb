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
      },
      {
        name: "google_setup",
        description: "Manage Google account setup for the current user. Use 'check' to see if Google is configured, 'start' to begin OAuth flow, 'complete' to finish it, or 'generate_link' to create a web setup URL.",
        input_schema: {
          "type" => "object",
          "properties" => {
            "action" => {
              "type" => "string",
              "enum" => ["check", "start", "complete", "generate_link"],
              "description" => "The setup action to perform"
            },
            "email" => {
              "type" => "string",
              "description" => "Google email address (required for start and complete)"
            },
            "auth_url" => {
              "type" => "string",
              "description" => "The redirect URL containing the auth code (required for complete)"
            }
          },
          "required" => ["action"]
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
