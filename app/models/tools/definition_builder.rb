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
      },
      {
        name: "download_file",
        description: "Download a file from a URL and save it locally. Use this to fetch documents, images, data files, or any other content from the web for later reference.",
        input_schema: {
          "type" => "object",
          "properties" => {
            "url" => { "type" => "string", "description" => "The HTTP or HTTPS URL to download" },
            "filename" => { "type" => "string", "description" => "Optional filename to save as (defaults to name from URL)" }
          },
          "required" => ["url"]
        }
      },
      {
        name: "schedule_task",
        description: "Schedule a task to run at a specific time, optionally recurring. The task will inject a message into this conversation and trigger a response.",
        input_schema: {
          "type" => "object",
          "properties" => {
            "description" => { "type" => "string", "description" => "What the task should do when it fires" },
            "run_at" => { "type" => "string", "description" => "When to run (ISO 8601 datetime, e.g. '2025-01-15T09:00:00Z')" },
            "interval" => {
              "type" => "string",
              "enum" => ["once", "hourly", "daily", "weekly", "custom"],
              "description" => "How often to repeat (default: once)"
            },
            "interval_seconds" => { "type" => "integer", "description" => "Custom repeat interval in seconds (required when interval is 'custom')" }
          },
          "required" => ["description", "run_at"]
        }
      },
      {
        name: "list_scheduled_tasks",
        description: "List all scheduled tasks for the current conversation.",
        input_schema: {
          "type" => "object",
          "properties" => {}
        }
      },
      {
        name: "cancel_scheduled_task",
        description: "Cancel a scheduled task by its ID.",
        input_schema: {
          "type" => "object",
          "properties" => {
            "task_id" => { "type" => "integer", "description" => "The ID of the scheduled task to cancel" }
          },
          "required" => ["task_id"]
        }
      }
    ].freeze

    SEND_MESSAGE_TOOL = {
      name: "send_message",
      description: "Send a message to the user via their Telegram chat. Use this in background processing mode to notify the user about important events. Only send messages worth interrupting the user for.",
      input_schema: {
        "type" => "object",
        "properties" => {
          "text" => { "type" => "string", "description" => "The message text to send to the user" }
        },
        "required" => ["text"]
      }
    }.freeze

    def initialize(agent:, conversation: nil)
      @agent = agent
      @conversation = conversation
    end

    def call
      tools = @agent.enabled_tools.map(&:to_anthropic_tool)
      tools.concat(BUILTIN_TOOLS)
      tools << SEND_MESSAGE_TOOL if @conversation&.background?
      tools.presence
    end
  end
end
