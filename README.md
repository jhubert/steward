# Steward

A multi-agent AI platform that runs on a single Linux server. Steward is a hiring agency for AI — the Steward bot is the reception desk, and each agent is a separate hire with its own Telegram bot, personality, and expertise.

Supports multiple users concurrently with strict tenant isolation, layered memory, composable skills, and tool use.

## How it works

Each **Agent** is an independent Telegram bot with its own identity, system prompt, and set of tools. Users message agents directly on Telegram. The platform handles:

- **Prompt assembly** from layered memory (system prompt, principal context, skills, conversation state, recent history, long-term recall)
- **Rolling summarization** to keep conversations within context limits
- **Memory extraction** — structured facts are pulled from every exchange for long-term recall
- **Tool execution** — agents can run external scripts via a safe subprocess executor
- **Scheduled tasks** — recurring or one-time tasks, with optional direct tool execution that skips the LLM when running deterministic scripts
- **Multi-principal awareness** — agents serving multiple users understand who they're talking to and maintain appropriate discretion

## Stack

- Ruby 3.4, Rails 8.1, PostgreSQL
- Solid Queue for background jobs
- Anthropic Claude API for LLM calls
- pgvector for semantic memory search
- Caddy as reverse proxy

## Setup

```bash
# Install dependencies
bundle install

# Set up credentials (requires EDITOR)
bin/rails credentials:edit
# Required keys:
#   anthropic:
#     api_key: ...
#   telegram:
#     bot_token: ...        # fallback token
#   active_record_encryption:
#     primary_key: ...
#     deterministic_key: ...
#     key_derivation_salt: ...

# Create and seed the database
bin/rails db:create db:migrate db:seed

# Run the server
PORT=3003 bin/rails server

# Start the job worker (processes LLM calls, scheduled tasks, etc.)
bundle exec rake solid_queue:start
```

## Adding an agent

```ruby
agent = Agent.create!(
  workspace: Workspace.find_by(slug: "default"),
  name: "Researcher",
  system_prompt: "You are a research assistant...",
  settings: { "telegram_bot_token" => "TOKEN_FROM_BOTFATHER" }
)
```

Then register the webhook:

```bash
bin/rails telegram:set_webhook[Researcher]
```

The agent is now live at `https://your-domain/webhooks/telegram/:agent_id`.

## Tools

Agents can execute external scripts. Tools are database records with a command template, working directory, and optional encrypted credentials.

```ruby
AgentTool.create!(
  workspace: agent.workspace,
  agent: agent,
  name: "check_weather",
  description: "Check the current weather for a city",
  input_schema: {
    "type" => "object",
    "properties" => { "city" => { "type" => "string" } },
    "required" => ["city"]
  },
  command_template: "python3 weather.py {city}",
  working_directory: "/srv/steward/skills/weather",
  timeout_seconds: 15
)
```

Commands run via `Open3.capture3` with argv arrays — no shell, safe from injection. Credentials are injected as environment variables at runtime.

## Scheduled tasks

Tasks can be created by agents via the `schedule_task` tool, or directly in the console. Two modes:

- **LLM-based** — triggers a background conversation with the agent on each run
- **Direct execution** — runs a tool directly and only involves the LLM if there's output to act on (ideal for polling scripts)

```ruby
# Direct execution: check email every 10 minutes, only wake the LLM on new mail
ScheduledTask.create!(
  workspace: agent.workspace,
  agent: agent,
  user: user,
  agent_tool: agent.agent_tools.find_by(name: "check_email"),
  description: "Check for new email",
  next_run_at: 10.minutes.from_now,
  interval_seconds: 600,
  tool_input: {}
)
```

## Skills

Skills follow the [Agent Skills spec](https://agentskills.io/specification) and live in `skills/` as directories with a `SKILL.md` file. They are activated per-conversation and provide domain-specific instructions to the agent.

## Testing

```bash
bin/rails test
```

Minitest with fixtures. Tests cover models, adapters, prompt assembly, skills, principal context, tool execution, and job pipelines.

## Architecture

See [CLAUDE.md](CLAUDE.md) for detailed architecture documentation, including the memory layer system, multi-tenancy model, adapter pattern, and key file reference.
