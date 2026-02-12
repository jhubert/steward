# Steward — Build Plan

## Design Origin

This architecture was designed from a detailed write-up covering multi-threaded agent design with strict isolation, layered memory, and cross-thread awareness. The full design principles are captured here for continuity.

### Core Design Principle

Every response is assembled from layers of memory, not from "the conversation." Isolation is enforced at the data layer, not by prompting.

### Identity & Scope Hierarchy

All data is scoped by: `workspace_id` → `user_id` → `thread_id` → `channel`

**Hard rule:** A model call may only access data matching `(workspace_id, user_id)` unless explicitly marked shared.

---

## Phase 1 — Core Agent (COMPLETE)

Multi-agent platform with Telegram, multi-user isolation, layered memory, and skills.

### What was built

- [x] Rails 8.1 app at `/srv/steward`
- [x] Schema: workspaces, users, agents, conversations, messages, conversation_states, memory_items
- [x] WorkspaceScoped concern for tenant isolation
- [x] Prompt::Assembler — builds messages array from Layer A + S + B + C
- [x] Compaction::Summarizer — rolling summarization via LLM
- [x] ProcessMessageJob — single-writer lock, LLM call, adapter reply
- [x] CompactConversationJob — triggers when unsummarized messages > 20
- [x] Adapters::Telegram — normalize, send_typing, send_reply (per-agent bot tokens)
- [x] Skills::Registry — loads SKILL.md files from filesystem
- [x] WebhooksController — routes webhooks to agents via `/webhooks/telegram/:agent_id`
- [x] Multi-agent support — each agent has its own Telegram bot, token, and webhook URL
- [x] Platform bot: @AgentStewardBot (Steward agent, the "reception desk")
- [x] Caddy reverse proxy: steward.boardwise.co → localhost:3003
- [x] Per-agent rake tasks: `telegram:set_webhook[AgentName]`, `telegram:set_all_webhooks`
- [x] 32 tests passing
- [x] Typing indicator in Telegram

---

## Phase 2 — Memory Extraction & Cross-Thread Retrieval

**Goal:** The agent remembers things across conversations and can recall relevant context from past threads.

### 2a. Memory Item Extraction

After each assistant reply, extract structured facts into `memory_items`:

- **Categories**: decision, preference, fact, commitment, span_summary
- **Extraction method**: Second LLM call (can use Haiku for cost) that reads the latest exchange and outputs structured items
- **Storage**: Each item scoped to `(workspace_id, user_id)`, optionally tied to a conversation
- **Job**: `ExtractMemoryJob` — runs async after response, not blocking the reply

### 2b. Embeddings with pgvector

- Add `vector` column to `memory_items` (1536 dimensions for Anthropic/OpenAI embeddings)
- Generate embeddings via API when memory items are created
- Add the `neighbor` gem for ActiveRecord integration

### 2c. Cross-Thread Retrieval

- **Thread Catalog**: Each conversation stores a title and stub summary (1-2 lines) in its metadata. Agent can "know" other threads exist without seeing content.
- **Retrieval triggers**: Explicit references ("as discussed before"), shared entities, agent uncertainty
- **Search scope**: Same `(workspace_id, user_id)` only. Hybrid retrieval: keyword match + embedding similarity + recency weighting
- **What gets sent**: Relevant memory items and short excerpts, never entire transcripts
- **Presentation**: Agent distinguishes "I know this" from "I found this in another thread"

### 2d. Hierarchical Span Summaries

- Periodically summarize message ranges (e.g., messages 1-50, 51-100) into chunk summaries
- Store as memory items with category `span_summary`
- Used only via retrieval — not sent in every prompt
- Protects against summary drift by preserving recoverable detail

### Deliverables

- [ ] ExtractMemoryJob
- [ ] Memory extraction prompt (tuned for structured output)
- [ ] pgvector column + neighbor gem
- [ ] Embedding generation on memory item creation
- [ ] Cross-thread retrieval in Prompt::Assembler (Layer D)
- [ ] Thread catalog (title + stub in conversation metadata)
- [ ] Retrieval trigger logic (entity/keyword match first, LLM classification later)
- [ ] Span summary generation job
- [ ] Tests for extraction, retrieval, and isolation

---

## Phase 3 — Email Adapter & Admin

**Goal:** Add email as a second channel and a basic admin dashboard.

### 3a. Email Adapter (ActionMailbox)

- Rails ActionMailbox for inbound email processing
- Thread detection via `In-Reply-To` / `References` headers, fallback to subject+sender matching
- Email content extraction (strip signatures, disclaimers, forwarded content)
- ActionMailer for outbound replies
- Adapter: `Adapters::Email` following the same contract

### 3b. Admin Dashboard

- Basic web UI for inspecting state:
  - Workspaces, users, conversations list
  - Conversation detail: messages, state, memory items
  - Agent configuration (system prompt, model, token budgets)
  - Skill management
  - Job monitoring (failed jobs, retry)
- Authentication: simple token or basic auth for Phase 3

### Deliverables

- [ ] ActionMailbox routing and Adapters::Email
- [ ] Email thread detection logic
- [ ] Email content extraction (signature stripping)
- [ ] Admin controllers and views
- [ ] Agent configuration UI

---

## Phase 4 — Production Hardening

**Goal:** Make it reliable and observable.

### 4a. Observability

- Structured logging of every prompt assembly: layers included, tokens per layer, retrieval results, latency
- Log every LLM call: model, input/output tokens, latency, cost estimate
- Failed job alerting

### 4b. Token Budget Enforcement

- Hard limits per layer in Prompt::Assembler with graceful degradation
- Truncate Layer C (history) before Layer B (state)
- Drop Layer D (retrieval) if not needed
- Log when budgets are exceeded

### 4c. User Corrections

- When user says "that's wrong" or corrects a fact, update:
  - Pinned facts in conversation state
  - Relevant memory items (mark old as superseded, create corrected version)
- Explicit mechanism, not just hoping the LLM picks it up

### 4d. Rate Limiting & Error Handling

- Per-user rate limiting on incoming messages
- Graceful error messages when LLM is unavailable
- Retry with exponential backoff (already in place for jobs)
- Circuit breaker for Telegram API failures

### 4e. Row-Level Security

- Enable Postgres RLS policies as belt-and-suspenders on top of WorkspaceScoped
- `SET LOCAL app.current_workspace_id` at the start of every job

### Deliverables

- [ ] Structured prompt assembly logging
- [ ] Token budget enforcement with degradation
- [ ] User correction mechanism
- [ ] Rate limiting
- [ ] Graceful error responses to users
- [ ] Postgres RLS policies

---

## Future Considerations

- **Tool use**: Agent can take actions (search, create calendar events, query APIs). Requires tool definitions, confirmation flows, error handling.
- **Multi-turn tool chains**: "Remind me tomorrow" → store → trigger → resume. Needs a lightweight scheduler.
- **Webhook adapter**: Generic webhook input for custom integrations.
- **Slack/WhatsApp adapters**: Same pattern as Telegram.
- **Conversation branching**: `/new` and `/topic` commands in Telegram to start new threads within the same chat.
- **Agent discovery**: Steward bot helps users find and connect with available agents.

---

## Architecture Diagram

```
  @StewardBot        @LawyerBot        @FriendBot
       │                  │                 │
       │ webhook          │ webhook         │ webhook
       ▼                  ▼                 ▼
  /webhooks/         /webhooks/        /webhooks/
  telegram/1         telegram/2        telegram/3
       │                  │                 │
       └──────────────────┼─────────────────┘
                          │
                 ┌────────▼────────┐
                 │WebhooksController│
                 │                  │
                 │ Resolve agent    │
                 │ by :agent_id     │
                 └────────┬────────┘
                          │ normalize, find/create user + conversation
                          │ enqueue
                 ┌────────▼────────┐
                 │ProcessMessageJob │
                 │                  │
                 │ 1. Lock convo    │
                 │ 2. Send typing   │
                 │ 3. Assemble prompt│
                 │ 4. Call LLM      │
                 │ 5. Store reply   │
                 │ 6. Send reply    │
                 │ 7. Maybe compact │
                 └────────┬────────┘
                          │
           ┌──────────────┼──────────────┐
           │              │              │
  ┌────────▼───┐  ┌──────▼──────┐ ┌────▼──────┐
  │  Prompt::   │  │ Anthropic   │ │ Compaction│
  │  Assembler  │  │ Claude API  │ │ Summarizer│
  │             │  │             │ │           │
  │ Layer A: Core│  └─────────────┘ └───────────┘
  │ Layer S: Skills│
  │ Layer B: State │
  │ Layer C: History│
  │ Layer D: Recall │ (Phase 2)
  └────────────────┘

Storage: PostgreSQL (all tables workspace-scoped)
Jobs: Solid Queue
Skills: Filesystem (skills/*.md)
Each agent = its own Telegram bot, token, and webhook URL
```

---

## Key Files

| File | Purpose |
|------|---------|
| `app/models/concerns/workspace_scoped.rb` | Tenant isolation concern |
| `app/models/current.rb` | Current.workspace thread-local |
| `app/models/prompt/assembler.rb` | Builds LLM messages array from memory layers |
| `app/models/compaction/summarizer.rb` | Rolling conversation summary via LLM |
| `app/models/adapters/telegram.rb` | Telegram webhook normalization + reply |
| `app/models/adapters/base.rb` | Adapter interface |
| `app/models/skills/registry.rb` | Loads SKILL.md files, singleton |
| `app/jobs/process_message_job.rb` | Core message processing pipeline |
| `app/jobs/compact_conversation_job.rb` | Triggers rolling summarization |
| `app/controllers/webhooks_controller.rb` | Receives Telegram webhooks |
| `config/initializers/anthropic.rb` | ANTHROPIC_CLIENT constant |
| `lib/tasks/telegram.rake` | Webhook management rake tasks |
| `db/seeds.rb` | Default workspace + Steward agent |
| `skills/example/SKILL.md` | Example skill template |
