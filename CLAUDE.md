# Steward

A multi-user AI agent hosted on a Linux server, supporting Telegram (and eventually email and other channels). Strict isolation between users, layered memory, and composable skills.

## Commands

```bash
PORT=3003 bin/rails server -d         # Start server (daemonized, port 3003)
bin/rails restart                     # Restart after code changes
bundle exec rake solid_queue:start    # Start job worker (processes LLM calls)
bin/rails test                        # Run tests
bin/rails db:seed                     # Seed default workspace + agent

# Telegram webhook management
bin/rails telegram:set_webhook[https://steward.boardwise.co/webhooks/telegram]
bin/rails telegram:delete_webhook
bin/rails telegram:webhook_info
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

### Multi-Tenancy & Isolation

- **Workspace** = tenant boundary (equivalent to Organization in Boardwise)
- **WorkspaceScoped** concern on all models, scopes via `Current.workspace`
- Every query filters by `(workspace_id, user_id)` — no cross-user data access
- Users are auto-created on first message from a new Telegram chat

### Adapters Pattern

Channels (Telegram, email, future) are **adapters** — the agent core is channel-agnostic.

```
[Telegram Adapter] ──→ WebhooksController ──→ ProcessMessageJob ──→ LLM
[Email Adapter]    ──→ (future)               ↕
[Future Adapter]   ──→                    Memory System
```

Adapter contract: `normalize(raw_params)`, `send_reply(conversation, message)`, `send_typing(conversation)`

### Key Models

| Model | Purpose |
|-------|---------|
| Workspace | Tenant boundary |
| User | A human, scoped to workspace. `external_ids` jsonb stores channel identifiers |
| Agent | Bot persona with system prompt and settings |
| Conversation | One per thread per user per channel |
| Message | Append-only log (roles: user, assistant, system) |
| ConversationState | Layer B: summary, pinned_facts, active_goals, summarized_through pointer |
| MemoryItem | Layer D: extracted facts/decisions (Phase 2) |

### Jobs

- **ProcessMessageJob**: Locks conversation → assembles prompt → calls Anthropic → stores reply → sends via adapter. Single-writer per conversation.
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

## Infrastructure

- **Domain**: steward.boardwise.co
- **Caddy** reverse proxies to localhost:3003
- **Telegram bot**: @AgentStewardBot
- **Credentials**: `bin/rails credentials:edit` — contains `telegram.bot_token` and `anthropic.api_key`
- **Database**: steward_development / steward_test on local Postgres

## Testing

- Minitest with fixtures
- `as_workspace(:default)` in setup to set Current.workspace
- Fixtures: workspaces (default, other), users (alice, bob, eve), agents (steward), conversations (alice_telegram), messages (alice_hello, steward_reply)
- 32 tests covering models, adapters, prompt assembly, skills
