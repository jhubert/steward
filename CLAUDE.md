# Steward

A multi-agent AI platform hosted on a Linux server. Think of Steward as a hiring agency — the Steward bot is the reception desk, and each agent is a separate hire with its own Telegram bot, personality, and expertise. Supports multiple users concurrently with strict isolation, layered memory, and composable skills.

## Commands

```bash
PORT=3003 bin/rails server -d                    # Start server (daemonized, port 3003)
bin/rails restart                                # Restart after code changes
bundle exec rake solid_queue:start               # Start job worker (processes LLM calls)
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
2. **Layer S — Active Skills**: SKILL.md instructions loaded on demand
3. **Layer B — Conversation State**: Rolling summary, pinned facts, active goals (always sent)
4. **Layer C — Recent Messages**: Sliding window of recent history (always sent)
5. **Layer D — Long-Term Recall**: Retrieved memory items (only when relevant, Phase 2)

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
| ConversationState | Layer B: summary, pinned_facts, active_goals, summarized_through pointer |
| MemoryItem | Layer D: extracted facts/decisions (Phase 2) |

### Jobs

- **ProcessMessageJob**: Locks conversation → sends typing → assembles prompt → calls Anthropic → stores reply → sends via adapter. Single-writer per conversation.
- **CompactConversationJob**: Rolling summarization when unsummarized messages exceed threshold (20). Runs after response is sent.

### Skills

Skills follow the [Agent Skills spec](https://agentskills.io/specification). They live in `skills/` as directories with a `SKILL.md` file.

- `Skills::Registry` (singleton) loads all skill metadata at boot
- Skills are activated per-conversation via `conversation.metadata["active_skills"]`
- Phase 1: manual opt-in. Phase 2: automatic activation based on message content.

## Conventions

- **No service objects.** Domain logic on models, POROs in `app/models/<namespace>/` for concepts (Prompt::Assembler, Compaction::Summarizer, Adapters::Telegram, Skills::Registry).
- **Date/Time**: Always `Date.current` / `Time.current`.
- **LLM client**: Use the `ANTHROPIC_CLIENT` constant (initialized in `config/initializers/anthropic.rb`). API: `ANTHROPIC_CLIENT.messages.create(model:, max_tokens:, system:, messages:)`. Response: `response.content.first.text`, `response.usage.output_tokens`.
- **Token budgets**: Defined per agent in `agent.settings["token_budgets"]`. Defaults: agent_core=800, skills=2000, state=1500, history=4000, response=4000.
- **Per-agent bot tokens**: `agent.telegram_bot_token` reads from `settings["telegram_bot_token"]`, falling back to global `credentials.telegram.bot_token`.

## Infrastructure

- **Domain**: steward.boardwise.co
- **Caddy** reverse proxies to localhost:3003
- **Platform bot**: @AgentStewardBot (Steward agent, id=1)
- **Credentials**: `bin/rails credentials:edit` — contains `telegram.bot_token` (fallback) and `anthropic.api_key`
- **Database**: steward_development / steward_test on local Postgres
- **Webhook URLs**: `https://steward.boardwise.co/webhooks/telegram/:agent_id`

## Testing

- Minitest with fixtures
- `as_workspace(:default)` in setup to set Current.workspace
- Fixtures: workspaces (default, other), users (alice, bob, eve), agents (steward), conversations (alice_telegram), messages (alice_hello, steward_reply)
- 32 tests covering models, adapters, prompt assembly, skills

## Key Files

| File | Purpose |
|------|---------|
| `app/models/agent.rb` | Bot persona, model/token config, telegram_bot_token |
| `app/models/concerns/workspace_scoped.rb` | Tenant isolation concern |
| `app/models/current.rb` | Current.workspace thread-local |
| `app/models/prompt/assembler.rb` | Builds LLM messages array from memory layers |
| `app/models/compaction/summarizer.rb` | Rolling conversation summary via LLM |
| `app/models/adapters/telegram.rb` | Telegram normalization + typing + reply |
| `app/models/adapters/base.rb` | Adapter interface |
| `app/models/skills/registry.rb` | Loads SKILL.md files, singleton |
| `app/jobs/process_message_job.rb` | Core message processing pipeline |
| `app/jobs/compact_conversation_job.rb` | Triggers rolling summarization |
| `app/controllers/webhooks_controller.rb` | Routes webhooks to agents by :agent_id |
| `config/initializers/anthropic.rb` | ANTHROPIC_CLIENT constant |
| `lib/tasks/telegram.rake` | Per-agent webhook management |
| `db/seeds.rb` | Default workspace + Steward agent |
| `skills/example/SKILL.md` | Example skill template |
| `docs/plan.md` | Full build plan (Phases 1-4 + future) |
