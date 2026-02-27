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
        name: "remember",
        description: "Save an important fact to long-term memory. Use this when the user shares something worth remembering across all future conversations — a preference, decision, personal detail, or commitment. These memories persist permanently and are recalled in every conversation with this user.",
        input_schema: {
          "type" => "object",
          "properties" => {
            "content" => { "type" => "string", "description" => "A concise standalone statement in third person (e.g., 'Prefers morning meetings', 'Works at Acme Corp')" },
            "category" => {
              "type" => "string",
              "enum" => ["decision", "preference", "fact", "commitment"],
              "description" => "The type of memory: decision (a choice made), preference (a like/dislike), fact (a detail about the user), commitment (something promised for the future)"
            }
          },
          "required" => ["content", "category"]
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
        description: "Schedule a task to run at a specific time, optionally recurring. Without tool_name, the task triggers an LLM conversation. With tool_name, the tool runs directly and the LLM is only invoked if there's output to act on.",
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
            "interval_seconds" => { "type" => "integer", "description" => "Custom repeat interval in seconds (required when interval is 'custom')" },
            "tool_name" => { "type" => "string", "description" => "Name of an agent tool to execute directly (skips LLM for the execution step)" },
            "tool_input" => { "type" => "object", "description" => "Input parameters for the tool (used with tool_name)" }
          },
          "required" => ["description", "run_at"]
        }
      },
      {
        name: "list_scheduled_tasks",
        description: "List all scheduled tasks for the current user and agent.",
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
      },
      {
        name: "create_skill",
        description: "Create a new skill on the Steward platform. A skill is a directory with a SKILL.md file (instructions), optional tools.yml (tool definitions), and optional scripts. Use this to codify repeated workflows into reusable agent capabilities.",
        input_schema: {
          "type" => "object",
          "properties" => {
            "skill_name" => { "type" => "string", "description" => "Kebab-case skill name (e.g., 'restaurant-search'). Must contain only lowercase letters, numbers, and hyphens." },
            "description" => { "type" => "string", "description" => "One-line description for the skill catalog listing." },
            "instructions" => { "type" => "string", "description" => "Markdown body for SKILL.md (everything after the frontmatter). Include headings, when-to-use, and step-by-step instructions." },
            "tools_yaml" => { "type" => "string", "description" => "Optional YAML content for tools.yml. Must follow the tools.yml schema with a top-level 'tools' key." },
            "scripts" => { "type" => "object", "description" => "Optional map of script filename to content (e.g., {\"search.py\": \"#!/usr/bin/env python3\\n...\"}). Files are created in the scripts/ subdirectory with executable permissions." },
            "enable_for" => { "type" => "string", "description" => "Optional agent name to auto-enable this skill for (e.g., 'Jennifer Lawson')." }
          },
          "required" => ["skill_name", "description", "instructions"]
        }
      },
      {
        name: "recall",
        description: "Search your long-term memory with a targeted query. Use when you need to remember something specific — a past decision, preference, or fact — that isn't in your current context. Returns matching memories with source references you can follow up on with read_transcript.",
        input_schema: {
          "type" => "object",
          "properties" => {
            "query" => { "type" => "string", "description" => "Targeted search query describing what you want to remember" },
            "category" => {
              "type" => "string",
              "enum" => ["decision", "preference", "fact", "commitment"],
              "description" => "Optional: filter results to a specific memory type"
            }
          },
          "required" => ["query"]
        }
      },
      {
        name: "read_transcript",
        description: "Read original conversation messages. Use after `recall` to get full context around a remembered fact, or to review earlier parts of any conversation.",
        input_schema: {
          "type" => "object",
          "properties" => {
            "message_id" => { "type" => "integer", "description" => "Center point message ID to read around (from recall results)" },
            "conversation_id" => { "type" => "integer", "description" => "Which conversation to read from (defaults to current conversation)" },
            "before" => { "type" => "string", "description" => "Only include messages before this ISO datetime" },
            "after" => { "type" => "string", "description" => "Only include messages after this ISO datetime" }
          }
        }
      }
    ].freeze

    INVITE_USER_TOOL = {
      name: "invite_user",
      description: "Invite a new user to the platform by email. Creates their account and sends a welcome email from you. The user can then reply to start a conversation, and you can help them find and hire agents.",
      input_schema: {
        "type" => "object",
        "properties" => {
          "email" => { "type" => "string", "description" => "The email address to invite" },
          "name" => { "type" => "string", "description" => "Optional display name for the invitee" }
        },
        "required" => ["email"]
      }
    }.freeze

    SEND_MESSAGE_TOOL = {
      name: "send_message",
      description: "Send a message to the user via their Telegram chat. Use this in background processing mode to notify the user about important events. Only send messages worth interrupting the user for.",
      input_schema: {
        "type" => "object",
        "properties" => {
          "text" => { "type" => "string", "description" => "The message text to send to the user" },
          "context" => { "type" => "string", "description" => "Brief summary of what background activity prompted this message (e.g., 'Found urgent email from CEO about deadline change'). This context is stored so the user's reply can be understood in context." }
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
      tools << INVITE_USER_TOOL if @agent.settings&.dig("can_invite")
      tools.presence
    end
  end
end
