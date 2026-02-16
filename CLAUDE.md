# Steward

A multi-agent AI platform hosted on a Linux server. Think of Steward as a hiring agency — the Steward bot is the reception desk, and each agent is a separate hire with its own Telegram bot, personality, and expertise. Supports multiple users concurrently with strict isolation, layered memory, and composable skills.

## Commands

```bash
# Systemd services (Rails app + Solid Queue worker)
sudo systemctl restart steward                   # Restart Rails app (Puma on port 5000)
sudo systemctl restart steward-jobs              # Restart Solid Queue worker
sudo systemctl status steward steward-jobs       # Check status of both services
# Logs: log/puma.log, log/solid_queue.log

bin/rails test                                   # Run tests
bin/rails db:seed                                # Seed default workspace + Steward agent

# Telegram webhook management (per-agent)
bin/rails telegram:set_webhook[AgentName]        # Register webhook for one agent
bin/rails telegram:delete_webhook[AgentName]     # Remove webhook for one agent
bin/rails telegram:webhook_info[AgentName]       # Show webhook status for one agent
bin/rails telegram:set_all_webhooks              # Register webhooks for ALL agents
```

## Stack

Rails 8.1, Ruby 3.4, PostgreSQL, Solid Queue, Anthropic Claude API, HTTPX

## Architecture

### Core Concept

Every response is assembled from **scoped memory layers**, not from "the whole conversation." The system constructs a prompt per turn from:

1. **Layer A — Agent Core**: System prompt, personality, rules (always sent)
2. **Layer P — Principal Context**: Cross-principal awareness, roster, discretion guidelines, fellow principals' memories (only for principal-mode agents)
3. **Layer S — Active Skills**: SKILL.md instructions loaded on demand
4. **Layer B — Conversation State**: Rolling summary, pinned facts, active goals (always sent)
5. **Layer C — Recent Messages**: Sliding window of recent history (always sent)
6. **Layer D — Long-Term Recall**: Retrieved memory items (only when relevant, Phase 2)

### Multi-Agent Model

Steward is a platform, not a single bot. Each **Agent** is a separate Telegram bot with its own:
- Bot token (stored in `agent.settings["telegram_bot_token"]`)
- System prompt / personality
- Conversations (isolated per user per agent)
- Webhook URL: `/webhooks/telegram/:agent_id`

The **Steward** agent (@AgentStewardBot) is the platform's front door — for onboarding, discovering agents, etc. Other agents are the "hires" (a lawyer, a Canadian friend, a researcher, etc.).

**Adding a new agent:**
```ruby
Agent.create!(
  workspace: Workspace.find_by(slug: "default"),
  name: "Lawyer",
  system_prompt: "You are an experienced corporate lawyer...",
  settings: { "telegram_bot_token" => "TOKEN_FROM_BOTFATHER" }
)
```
Then: `bin/rails telegram:set_webhook[Lawyer]`

### Principal Model

Agents can optionally serve multiple **principals** (users). When an agent has principals, it gains cross-user awareness via **Layer P** in prompt assembly — it knows who it's talking to, who else it serves, and relevant facts about all its principals. Agents without principals are completely unaffected.

- `AgentPrincipal` — join model linking Agent ↔ User with role/display_name
- `agent.principal_mode?` — true when agent has any principals
- `agent.principal?(user)` — checks if user is a registered principal
- `agent.fellow_principals(user)` — other principals excluding given user
- `Prompt::PrincipalContext` — builds Layer P content (current speaker, roster, discretion guidelines, cross-principal memories)
- `ExtractMemoryJob` — dedup context expands to all principal user_ids in principal mode

### Multi-Tenancy & Isolation

- **Workspace** = tenant boundary
- **WorkspaceScoped** concern on all models, scopes via `Current.workspace`
- Every query filters by `(workspace_id, user_id)` — no cross-user data access
- Users are auto-created on first message from a new Telegram chat
- A user talking to Agent A has fully separate conversations from Agent B

### Adapters Pattern

Channels (Telegram, email, future) are **adapters** — the agent core is channel-agnostic.

Adapter contract:
- `initialize(bot_token:)` — per-agent credentials
- `normalize(raw_params)` — raw webhook → standard hash
- `send_reply(conversation, message)` — deliver response
- `send_typing(conversation)` — show typing indicator

### Key Models

| Model | Purpose |
|-------|---------|
| Workspace | Tenant boundary |
| User | A human, scoped to workspace. `external_ids` jsonb stores channel identifiers |
| Agent | Bot persona. Has its own Telegram bot token, system prompt, model settings |
| Conversation | One per thread per user per agent per channel |
| Message | Append-only log (roles: user, assistant, system) |
| AgentPrincipal | Join model: agent ↔ user with role, display_name, permissions |
| ConversationState | Layer B: summary, pinned_facts, active_goals, summarized_through pointer |
| MemoryItem | Layer D: extracted facts/decisions. Categories: decision, preference, fact, commitment |
| AgentTool | Per-agent tool definition: name, description, input_schema (JSON Schema), command_template, encrypted credentials, timeout |
| ToolExecution | Audit trail: records every tool call with input, output, exit_code, timing, timed_out flag |

### Tool Use

Agents can execute external scripts via Anthropic's tool use API. Tools are database records (per-agent), while skill instructions remain filesystem-based (Layer S).

**How it works:**
1. `Tools::DefinitionBuilder` reads `agent.enabled_tools` and returns Anthropic-compatible tool schemas
2. `ProcessMessageJob` passes `tools:` to the API and loops on `stop_reason == "tool_use"`
3. `Tools::Executor` runs commands via `Open3.capture3` with argv arrays (no shell — safe from injection)
4. Tool results feed back to the LLM as `tool_result` messages; loop continues until `end_turn`
5. Intermediate tool_use/tool_result rounds stay in memory only — only the final text reply is persisted
6. Each execution is logged to `tool_executions` for audit/debugging
7. Safety valve: max 10 tool rounds per message

**Adding a tool to an agent:**
```ruby
AgentTool.create!(
  workspace: Workspace.find_by(slug: "default"),
  agent: Agent.find_by(name: "Jennifer"),
  name: "find_availability",
  description: "Find available meeting slots for given attendees",
  input_schema: { "type" => "object", "properties" => { "attendees" => { "type" => "string" } }, "required" => ["attendees"] },
  command_template: "python3 find-availability.py {attendees} --duration {duration}",
  working_directory: "/srv/steward/skills/scheduling",
  credentials: { "GOOGLE_API_KEY" => "..." },
  timeout_seconds: 30
)
```

- `credentials_json` is encrypted via Active Record Encryption (env vars injected at runtime)
- `command_template` uses `{param}` placeholders substituted from LLM input
- Agents without tools behave exactly as before (no `tools:` param sent)

### Jobs

- **ProcessMessageJob**: Locks conversation → sends typing → assembles prompt → calls Anthropic with tool definitions → loops on tool_use responses (execute via Tools::Executor, feed results back) → stores final text reply → sends via adapter. Single-writer per conversation. Max 10 tool rounds.
- **CompactConversationJob**: Rolling summarization when unsummarized messages exceed threshold (20). Runs after response is sent.
- **ExtractMemoryJob**: Extracts structured facts (decision, preference, fact, commitment) from each user/assistant exchange into `MemoryItem` records. Runs on `:low_priority` queue after every reply. Uses `Memory::Extractor` with the agent's `extraction_model` (default: Haiku).

### Skills

Skills follow the [Agent Skills spec](https://agentskills.io/specification). They live in `skills/` as directories with a `SKILL.md` file.

- `Skills::Registry` (singleton) loads all skill metadata at boot
- Skills are activated per-conversation via `conversation.metadata["active_skills"]`
- Phase 1: manual opt-in. Phase 2: automatic activation based on message content.

## Conventions

- **No service objects.** Domain logic on models, POROs in `app/models/<namespace>/` for concepts (Prompt::Assembler, Compaction::Summarizer, Memory::Extractor, Adapters::Telegram, Skills::Registry, Tools::Executor, Tools::DefinitionBuilder).
- **Date/Time**: Always `Date.current` / `Time.current`.
- **LLM client**: Use the `ANTHROPIC_CLIENT` constant (initialized in `config/initializers/anthropic.rb`). API: `ANTHROPIC_CLIENT.messages.create(model:, max_tokens:, system:, messages:)`. Response: `response.content.first.text`, `response.usage.output_tokens`.
- **Token budgets**: Defined per agent in `agent.settings["token_budgets"]`. Defaults: agent_core=800, skills=2000, state=1500, history=4000, response=4000, principal_context=1200.
- **Per-agent bot tokens**: `agent.telegram_bot_token` reads from `settings["telegram_bot_token"]`, falling back to global `credentials.telegram.bot_token`.
- **Extraction model**: `agent.extraction_model` reads from `settings["extraction_model"]`, defaults to `claude-haiku-4-5-20251001` (cheap, runs on every message).

## Infrastructure

- **Domain**: steward.boardwise.co
- **Nginx** reverse proxies to localhost:5000
- **Platform bot**: @AgentStewardBot (Steward agent, id=1)
- **Credentials**: `bin/rails credentials:edit` — contains `telegram.bot_token` (fallback), `anthropic.api_key`, and `active_record_encryption` keys
- **Database**: steward_production (live data), steward_test (tests). The app runs in production mode.
- **Webhook URLs**: `https://steward.boardwise.co/webhooks/telegram/:agent_id`
- **IMPORTANT**: Always use `RAILS_ENV=production` when running `bin/rails runner`, `bin/rails console`, or any command that queries live data. The development database is empty — all real agents, conversations, and messages are in the production database.

## Testing

- Minitest with fixtures
- `as_workspace(:default)` in setup to set Current.workspace
- Fixtures: workspaces (default, other), users (alice, bob, eve), agents (steward, jennifer), agent_principals (jennifer_alice, jennifer_bob), agent_tools (jennifer_scheduling, jennifer_moxie, jennifer_disabled), conversations (alice_telegram, alice_jennifer, bob_jennifer), messages, memory_items
- 113 tests covering models, adapters, prompt assembly, skills, principal context, tool use, executor, definition builder

## Key Files

| File | Purpose |
|------|---------|
| `app/models/agent.rb` | Bot persona, model/token config, telegram_bot_token, principal helpers, tool helpers |
| `app/models/agent_tool.rb` | Per-agent tool definition with encrypted credentials, to_anthropic_tool |
| `app/models/agent_principal.rb` | Agent ↔ User join model with role/display_name |
| `app/models/tool_execution.rb` | Audit trail for tool calls (input, output, timing) |
| `app/models/concerns/workspace_scoped.rb` | Tenant isolation concern |
| `app/models/current.rb` | Current.workspace thread-local |
| `app/models/prompt/assembler.rb` | Builds LLM messages array from memory layers (A, P, S, B, C) |
| `app/models/prompt/principal_context.rb` | Builds Layer P: cross-principal awareness |
| `app/models/compaction/summarizer.rb` | Rolling conversation summary via LLM |
| `app/models/memory/extractor.rb` | Extracts structured facts from exchanges via LLM |
| `app/models/adapters/telegram.rb` | Telegram normalization + typing + reply |
| `app/models/adapters/base.rb` | Adapter interface |
| `app/models/skills/registry.rb` | Loads SKILL.md files, singleton |
| `app/models/tools/executor.rb` | Safe command execution via Open3.capture3 with argv arrays |
| `app/models/tools/definition_builder.rb` | Builds Anthropic tool definitions from agent's enabled tools |
| `app/jobs/process_message_job.rb` | Core message processing pipeline with tool use loop |
| `app/jobs/compact_conversation_job.rb` | Triggers rolling summarization |
| `app/jobs/extract_memory_job.rb` | Extracts memory items after each reply |
| `app/controllers/webhooks_controller.rb` | Routes webhooks to agents by :agent_id |
| `config/initializers/anthropic.rb` | ANTHROPIC_CLIENT constant |
| `lib/tasks/telegram.rake` | Per-agent webhook management |
| `db/seeds.rb` | Default workspace + Steward agent |
| `skills/example/SKILL.md` | Example skill template |
| `docs/plan.md` | Full build plan (Phases 1-4 + future) |
