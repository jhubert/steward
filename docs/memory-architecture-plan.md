# Memory Architecture — Human-Like Continuity Plan

## Goal

Make Steward agents feel like long-term human collaborators:

1. **Continuity** across channels and time — talking to the agent on Telegram, then email, then Telegram again should feel like one relationship, not three isolated threads.
2. **Time-awareness** — the agent knows when things happened, how long ago, and how recent activity relates to past activity.
3. **Deep recall** — when something is mentioned in passing, the agent can dig down to specifics (the actual exchange, not just an extracted summary).
4. **Privacy** — cross-principal isolation stays airtight; provenance is always clear when the agent draws on another principal's information.

PostgreSQL is the unfair advantage. We already use `pgvector` for embeddings, JSONB for metadata, and have full-text search available. We should lean into it: durable, queryable, indexable memory beats opaque summaries.

## Current State (Recap)

Three storage substrates today:

- `messages` — raw transcripts (no embeddings)
- `conversation_states` — per-thread rolling summary + ephemeral state
- `memory_items` — extracted facts, per (workspace, user, agent), with embeddings

Five prompt layers (A, P, S, B, C, D) all scope to the *current conversation*. The only cross-conversation bridges are `thread_catalog` (text snippets when summaries exist), `cross_principal_memories` (last 20 facts per fellow principal), and `recall` / `read_transcript` (on-demand tools).

Limitations identified in prior analysis:
- Continuity is conversation-bound, not relationship-bound
- Time is missing from almost every memory render
- Transcripts are unsearchable except by pointer
- No episodic memory
- No memory supersession
- Cross-principal labeling is inconsistent

## Target Architecture

Three memory dimensions, mapped to human analogs:

| Human concept | Substrate | Implementation |
|---------------|-----------|----------------|
| Working memory | `ConversationState` (this thread) + `AgentUserState` (this relationship) | Per-conv + per-(user,agent) |
| Episodic memory | `Episode` + searchable `Message` transcripts | New table + message embeddings |
| Semantic memory | `MemoryItem` (with supersession + dating) | Existing + augmented |

Plus a cross-channel **timeline** assembled at prompt-build time, and an **audit log** for cross-principal memory touches.

## Schema Changes

### New tables

**`agent_user_states`** — relationship-level state distinct from per-conversation state. Exists for every (user, agent) pair the moment they interact.

```ruby
create_table :agent_user_states do |t|
  t.references :workspace, null: false, foreign_key: true
  t.references :user, null: false, foreign_key: true
  t.references :agent, null: false, foreign_key: true

  t.text :summary                       # rolling relationship summary across all channels
  t.jsonb :pinned_facts, default: []    # facts the agent wants to always remember (cross-channel)
  t.jsonb :active_goals, default: []    # in-flight projects/intents spanning channels
  t.jsonb :outgoing_commitments, default: []  # things the agent promised this user
  t.text :scratchpad                    # free-form relationship notes

  t.datetime :last_interaction_at       # most recent message across any channel
  t.datetime :last_summarized_at        # when summary last rebuilt
  t.bigint :summarized_through_message_id  # cursor across all this user's messages with this agent

  t.timestamps
end
add_index :agent_user_states, [:workspace_id, :user_id, :agent_id], unique: true
```

**`episodes`** — discrete narrative chunks. One episode = one coherent session within a conversation, bounded by session breaks or conversation completion.

```ruby
create_table :episodes do |t|
  t.references :workspace, null: false, foreign_key: true
  t.references :user, null: false, foreign_key: true
  t.references :agent, null: false, foreign_key: true
  t.references :conversation, null: false, foreign_key: true

  t.string :title                       # LLM-generated short label
  t.text :summary                       # 1-3 sentence narrative
  t.string :channel, null: false        # snapshot of the conversation's channel
  t.datetime :started_at, null: false
  t.datetime :ended_at, null: false
  t.bigint :first_message_id
  t.bigint :last_message_id
  t.vector :embedding, limit: 1536      # for semantic episode search
  t.jsonb :metadata, default: {}        # participants, sender info for email, etc.

  t.timestamps
end
add_index :episodes, [:workspace_id, :user_id, :agent_id, :started_at]
add_index :episodes, [:conversation_id, :started_at]
```

**`memory_access_logs`** — audit trail for cross-principal memory access (cheap insert-only table).

```ruby
create_table :memory_access_logs do |t|
  t.references :workspace, null: false, foreign_key: true
  t.references :agent, null: false, foreign_key: true
  t.references :viewing_user, null: false, foreign_key: { to_table: :users }   # who saw the data
  t.references :subject_user, null: false, foreign_key: { to_table: :users }   # whose data was shown
  t.references :conversation, foreign_key: true
  t.string :context                     # 'recall_tool' | 'principal_context' | 'cross_channel_hint'
  t.integer :memory_item_id             # nullable
  t.timestamps
end
add_index :memory_access_logs, [:workspace_id, :agent_id, :subject_user_id, :created_at]
```

### Augmented tables

**`messages`** — add embedding + denormalized scope columns for fast cross-channel queries.

```ruby
add_column :messages, :embedding, :vector, limit: 1536
add_column :messages, :embedded_at, :datetime
add_column :messages, :user_id, :bigint        # denormalized from conversation for fast joins
add_column :messages, :agent_id, :bigint       # denormalized

add_index :messages, [:user_id, :agent_id, :created_at]
add_index :messages, [:embedding], using: :hnsw, opclass: :vector_cosine_ops  # if pgvector >= 0.5
```

Backfill `user_id` / `agent_id` from `conversation_id` (one-time migration). Set them on create via a callback on `Message`.

**`memory_items`** — supersession + temporal anchoring.

```ruby
add_reference :memory_items, :supersedes, foreign_key: { to_table: :memory_items }
add_column :memory_items, :superseded_at, :datetime  # set on the OLD item when a new one supersedes it
add_column :memory_items, :observed_at, :datetime    # when the fact was true (vs. created_at = when extracted)
add_column :memory_items, :confidence, :float        # 0-1, set by extractor
add_column :memory_items, :search_vector, :tsvector  # generated column for fast keyword search

add_index :memory_items, :search_vector, using: :gin
add_index :memory_items, [:workspace_id, :user_id, :agent_id, :superseded_at]
```

The default retriever scope becomes `where(superseded_at: nil)` — old facts stay in the DB for audit but don't surface.

Extend `VALID_CATEGORIES` in `Memory::Extractor`:

```ruby
VALID_CATEGORIES = %w[decision preference fact commitment episode observation].freeze
```

- `episode`: a notable past exchange ("we discussed school options on Apr 14")
- `observation`: tone/context/relationship signal ("seemed stressed about the move") — only surfaced in same-user contexts, never in cross-principal layer

## Code Changes — File by File

### Models

**`app/models/agent_user_state.rb`** (new)
```ruby
class AgentUserState < ApplicationRecord
  include WorkspaceScoped
  belongs_to :user
  belongs_to :agent

  def self.for(user:, agent:)
    find_or_create_by!(workspace: user.workspace, user: user, agent: agent)
  end

  def touch_interaction!(message)
    update!(last_interaction_at: message.created_at)
  end

  def unsummarized_messages
    Message.where(user_id: user_id, agent_id: agent_id)
           .where('id > ?', summarized_through_message_id || 0)
           .order(:id)
  end
end
```

**`app/models/episode.rb`** (new)
```ruby
class Episode < ApplicationRecord
  include WorkspaceScoped
  has_neighbors :embedding
  belongs_to :user
  belongs_to :agent
  belongs_to :conversation

  scope :for_user_agent, ->(u, a) { where(user: u, agent: a) }
  scope :recent, -> { order(started_at: :desc) }
end
```

**`app/models/memory_access_log.rb`** (new) — trivial AR model, no business logic.

**`app/models/message.rb`** — add `belongs_to :agent`, callback to denormalize `user_id` / `agent_id` from conversation on create, scope `with_embedding`, `recently_for(user, agent, since:)`.

**`app/models/memory_item.rb`** — default scope `current` (`where(superseded_at: nil)`); helper `supersede!(by:)`.

**`app/models/conversation.rb`** — add `episodes` association, `idle_for?(hours)`, `stale_for_compaction?`, `stale_for_extraction?` per prior plan.

### Memory pipeline

**`app/models/memory/extractor.rb`**
- Extend `VALID_CATEGORIES`.
- Update extraction prompt: ask for `confidence` (0–1), `observed_at` (ISO date or null), and supersession hints.
- Add "supersession check" step: when extracting, pass the most relevant existing memories (by embedding similarity) and ask the model to flag any that the new fact replaces.
- In principal mode, **stop deduping against other principals' memories** — pass only the current user's known facts as context.

**`app/models/memory/retriever.rb`**
- `format` includes `(observed_at || created_at)` on every line. Use relative dates (`2 weeks ago`, `today`) when within 90 days, absolute dates otherwise.
- Default scope adds `where(superseded_at: nil)`.
- `search` in principal mode returns items annotated with `subject_user_id` so callers can label provenance.

**`app/models/memory/episode_builder.rb`** (new)
- Called when a conversation hits a session break or an idle sweep determines it's "complete enough."
- Pulls the message range, runs a short LLM call to produce `title` + `summary`, computes embedding, inserts `Episode` row.

**`app/models/memory/consolidator.rb`** (new) — periodic job-driven pass that:
- Loads recent un-consolidated memories per (user, agent)
- Asks the model to identify supersession/duplication
- Applies `supersede!` updates
- Bounded to N items per run; runs nightly via the existing scheduled-task infrastructure or a new cron entry.

### Prompt assembly

**`app/models/prompt/assembler.rb`** — major restructure of `build_system_content`:

```
parts << platform_charter
parts << agent_core
parts << date_context
parts << relationship_context   # NEW: last_interaction_at, time-since, AgentUserState summary
parts << capabilities_context
parts << principal_context if principal_mode?
parts << skill_instructions if active_skills.any?
parts << conversation_state if has_conversation_state?
parts << long_term_recall if incoming_message
parts << recent_episodes        # NEW: list of recent Episodes for this (user, agent)
parts << cross_channel_timeline # NEW: rolling timeline across all channels
parts << thread_catalog         # REDUCED: only threads with summaries, not stubs
parts << background_activity_briefing unless background?
parts << background_context if background?
```

Key new methods:

- `relationship_context` — pulls `AgentUserState`, formats:
  ```
  ## Relationship Context
  Last interaction: 4 days ago (telegram). 18 prior conversations.

  ### Relationship Summary
  <agent_user_state.summary>

  ### Outgoing Commitments (you promised these)
  - Send Sarah the Q2 deck (made 2d ago, not yet done)
  - Follow up on the school visit (made 1w ago, status unclear)

  ### Active Goals
  - Help plan Jeremy's wife's birthday trip
  ```

- `cross_channel_timeline` — last 30 messages OR last 24h (whichever is smaller), across all this user's conversations with this agent, excluding the current one. Tag each line with `[<channel> <time>]`. Bounded by `budgets['cross_channel']`.

- `recent_episodes` — last 5 episodes for (user, agent), oldest first, with `[<date>] <title>: <summary>`.

**`app/models/prompt/principal_context.rb`** — `cross_principal_memories` now:
- Always labels each item with `[from <name>]` regardless of fellow count
- Includes dates on every line
- Logs a `MemoryAccessLog` for each fellow whose memories were surfaced

### Jobs

**`app/jobs/process_message_job.rb`**
- After persisting the user/assistant exchange, also `AgentUserState.for(user:, agent:).touch_interaction!(message)`.
- Sibling-sweep: enqueue compact/extract for stale sibling conversations of the same (user, agent).
- Enqueue `EmbedMessageJob` for new messages.

**`app/jobs/compact_conversation_job.rb`** — idle trigger per prior plan. On completion, also enqueue `BuildEpisodeJob` if a session break was detected during the compaction.

**`app/jobs/extract_memory_job.rb`** — idle trigger + per-principal dedup + supersession suggestion.

**`app/jobs/embed_message_job.rb`** (new) — fetches OpenAI embedding for message content, writes to `messages.embedding`, sets `embedded_at`.

**`app/jobs/build_episode_job.rb`** (new) — given a message range, builds an `Episode`.

**`app/jobs/consolidate_memory_job.rb`** (new) — runs on a schedule (daily?) per (user, agent) pair; invokes `Memory::Consolidator`.

**`app/jobs/relationship_summary_job.rb`** (new) — rebuilds `AgentUserState#summary` when stale (e.g. last_summarized_at > 24h ago AND new activity since). Pulls recent messages across all channels, plus existing summary, plus episode titles, and produces a fresh relationship summary.

### Tools (`Tools::DefinitionBuilder` + executors)

**`recall`** — already exists. Update:
- In principal mode, format **always** labels `[from <name>]`.
- Add optional `time_range` argument (`last_week`, `last_month`, `since:<date>`).
- Add optional `include_superseded: false` flag (default false).
- Log `MemoryAccessLog` rows when results include other principals' memories.

**`recall_episodes`** (new tool) — semantic search over `Episode`s. Returns title/date/summary/conversation_id. Lets the agent locate the *narrative* of past sessions, not just facts.

**`search_transcripts`** (new tool) — semantic search over `messages.embedding`, returns top message snippets with conversation/channel/date and message_id, suitable for follow-up `read_transcript`. The "find the conversation where we discussed X" entry point.

**`read_transcript`** — already exists, mostly fine. Add: when called in principal mode against another principal's conversation, refuse and explain why.

## Implementation Phases

### Phase 1 — Foundation (cross-channel continuity + dates) — TARGET FIRST

Solves the user's immediate complaint and provides the lowest-risk wins.

1. Migration: `agent_user_states` table, `messages.user_id` / `messages.agent_id` denormalization + backfill.
2. Model: `AgentUserState` with `touch_interaction!`.
3. `Message` callback: set denormalized columns on create.
4. `Conversation`: add `idle_for?`, `stale_for_compaction?`, `stale_for_extraction?`.
5. `CompactConversationJob` / `ExtractMemoryJob`: OR-in idle triggers.
6. `ProcessMessageJob`: sibling-sweep enqueueing + `touch_interaction!`.
7. `Prompt::Assembler#cross_channel_timeline` — new method, slotted in.
8. `Prompt::Assembler` thread_catalog: drop stub one-liners (only render threads with summaries).
9. `Memory::Retriever#format`: include dates.
10. `Prompt::PrincipalContext#cross_principal_memories`: include dates + always-on labeling.
11. Backfill rake task: process all stale conversations once.
12. Tests: timeline rendering, idle triggers, dated memory rendering, current-conversation exclusion.

**Acceptance**: a fresh email from Jeremy after a recent Telegram exchange surfaces the Telegram turns verbatim in the email-side prompt. A memory dated 6 weeks ago renders as `(6 weeks ago)` not undated.

### Phase 2 — Relationship state + episodes

Builds the relationship-level layer and episode capture.

1. Migration: `episodes` table; `memory_items.supersedes_id`, `superseded_at`, `observed_at`, `confidence`, `search_vector` generated column + GIN index.
2. `Episode` model + `Memory::EpisodeBuilder` PORO.
3. `BuildEpisodeJob` — invoked on session break detection in `Conversation#compact_for_session_break!`.
4. Backfill: build episodes for all existing conversations using their session-break history (best-effort one-shot).
5. `RelationshipSummaryJob` — periodic rebuild of `AgentUserState#summary`.
6. `Prompt::Assembler#relationship_context` + `recent_episodes` sections.
7. Tests: episode creation on session break, relationship summary rebuild, prompt rendering of both.

**Acceptance**: after 3 distinct sessions on email + Telegram, the agent's prompt shows a relationship summary plus 3 episode entries with dates and titles. An agent can naturally reference "when we talked on Tuesday" because that episode is in the prompt.

### Phase 3 — Deep recall (message embeddings + new tools)

1. Migration: `messages.embedding`, `embedded_at`, hnsw index.
2. `EmbedMessageJob` + enqueue on message create.
3. Backfill: embed historical messages in batches, throttled to avoid blowing the OpenAI quota.
4. `recall_episodes` tool + executor.
5. `search_transcripts` tool + executor.
6. `recall` tool: time-range filter, superseded-flag, labeling fix.
7. Tests: episode search, transcript search, recall labeling in principal mode.

**Acceptance**: the agent can answer "what did we decide about X last spring?" by calling `search_transcripts` → `read_transcript` even if no `MemoryItem` was extracted at the time.

### Phase 4 — Privacy + consolidation

1. Migration: `memory_access_logs` table.
2. Insert `MemoryAccessLog` rows from `PrincipalContext#cross_principal_memories` and `recall` tool in principal mode.
3. Admin view exposing access logs (extend `/admin/users`).
4. `Memory::Consolidator` + `ConsolidateMemoryJob` + nightly schedule (via `ScheduledTask` or solid_queue recurring).
5. `Memory::Extractor` — supersession-aware extraction (pass top-K similar memories, accept supersession suggestions in response).
6. `Memory::Extractor` — extend categories with `episode`, `observation`. Tag `observation`s for same-user-only surfacing.
7. `extract_memory_job.rb`: stop cross-principal dedup. Each principal's facts are extracted from their own context only.
8. Tests: consolidation supersedes correctly, access logs written, observations don't appear in cross-principal context.

**Acceptance**: a preference change is reflected (old superseded, new active), access logs show every cross-principal touch, observations stay private to the user they were made about.

### Phase 5 — Outgoing commitments + relationship signals (optional)

1. `AgentUserState#outgoing_commitments` — populated by extractor when assistant role makes a commitment.
2. New extraction pass dedicated to detecting agent-side promises (lightweight Haiku call).
3. Surface unfulfilled commitments at the top of `relationship_context`.
4. Opt-in per-agent setting `surface_cross_principal_activity` — when on, surfaces a redacted "Bob mentioned X today" hint via Layer P.

Defer until Phases 1–4 are stable.

## Postgres Leverage

We're already on `pgvector`; this plan adds:

- **HNSW indexes** on `messages.embedding` and `episodes.embedding` for fast ANN search at the scale we'll reach (10k+ messages per user is plausible). Falls back to IVFFlat if HNSW unavailable in the installed pgvector version.
- **Generated `tsvector` column** on `memory_items` + GIN index for keyword search that doesn't require per-query `ILIKE` scans. Optionally extend to `messages` if we want hybrid semantic+keyword on transcripts.
- **JSONB GIN indexes** on `memory_items.metadata` and `agent_user_states.outgoing_commitments` if we end up querying inside them.
- **Partial indexes**: `where(superseded_at: nil)` partial index on `memory_items` to keep the "current memories" path fast as the supersession chain grows.
- **`pg_trgm`** (optional) on `episodes.title` for fuzzy title lookup in tools.

All of this stays in one database, transactional with the rest of the app. No external vector store, no separate search service.

## Privacy Invariants (must hold in tests)

1. A `MemoryItem` belonging to user A is never surfaced in a prompt for user B *except* through `cross_principal_memories` in principal mode, which explicitly labels `[from <A>]`.
2. The `cross_channel_timeline` query filters by `messages.user_id = current_conversation.user_id`. No cross-user message leak even if the agent has many principals.
3. `read_transcript` refuses to read a conversation owned by a different user.
4. Memory items with category `observation` are excluded from `cross_principal_memories`.
5. `MemoryAccessLog` is written for every cross-principal memory surfacing (tested with a controller spec / job spec).

## Backfill / Migration Plan

Execution order matters since later migrations depend on data shape from earlier ones.

1. Deploy Phase 1 migrations.
2. Run backfill: populate `messages.user_id` / `agent_id` from conversation; create `AgentUserState` for every existing (user, agent) pair; set `last_interaction_at` from latest message.
3. Run `bin/rails runner` script enqueueing compact/extract for stale conversations.
4. Deploy Phase 2 migrations.
5. Backfill episodes from existing message history — best-effort one pass, won't be perfect for old data but improves over time.
6. Deploy Phase 3 migrations.
7. Embed-historical script: batch through `Message.where(embedding: nil)` in 100-at-a-time batches with a throttle. Monitor OpenAI cost.
8. Deploy Phase 4 migrations.
9. Backfill access logs from any pre-existing principal-mode conversations — skip, start logging forward only.

## Token Budgets

Add to `agent.token_budgets` defaults:

```ruby
{
  agent_core: 800,
  skills: 2000,
  state: 1500,                  # per-conversation state (existing)
  history: 4000,                # current conversation history (existing)
  response: 4000,
  principal_context: 1200,      # existing
  relationship_context: 1000,   # NEW: AgentUserState rendering
  cross_channel: 1500,          # NEW (was implicit): timeline
  episodes: 800                 # NEW: recent_episodes section
}
```

Bumps total prompt size by ~3300 tokens worst-case for principal-mode agents with active cross-channel relationships. Within Claude 4.x context — fine.

## Testing Strategy

- **Unit**: model methods (`idle_for?`, `supersede!`, `for(user, agent)`), retriever formatting, extractor parsing of new categories.
- **Integration**: prompt assembler with fixtures covering: single-conversation user, multi-channel user, principal-mode user, cross-principal memory surfacing.
- **Scenario tests** (new): full pipeline tests that simulate "Telegram → email handoff" and assert the email prompt contains the Telegram exchange. Same for "session break → new session → references prior episode."
- **Privacy tests**: assert that user A's prompt never includes user B's messages or memories except in tagged cross-principal sections, with access log row created.
- **Migration tests**: backfill scripts run on a copy of production data without errors, idempotent on re-run.

## Open Questions to Resolve Before Each Phase

- **Phase 1**: should `cross_channel_timeline` include the agent's own outgoing messages on other channels, or just user messages? (Recommend: both — agent needs to know what it said.)
- **Phase 2**: episode boundaries — strictly session-break-driven, or also "manual" on conversation status change? (Recommend: both, with status change creating a final-episode marker.)
- **Phase 3**: embed model — `text-embedding-3-small` (existing) or `text-embedding-3-large` for richer message search? (Recommend: start with small; same model for messages and items so cosine distances are comparable.)
- **Phase 4**: should `observation`-category memories be available via `recall` for the *same* user, or hidden by default? (Recommend: available for same-user recall, never surfaced to other principals.)

## Risks

- **Embedding cost** at backfill. Mitigation: throttle, batch, monitor.
- **Prompt bloat** if every new section runs full budget. Mitigation: implement strict budget enforcement per section; tests for total prompt size.
- **Extraction quality regression** with new categories. Mitigation: keep `decision/preference/fact/commitment` core stable; gate `episode/observation` behind a feature flag on `agent.settings` initially.
- **Consolidation false positives** — model wrongly marks a current fact as superseded. Mitigation: consolidation runs as suggestions reviewed by a second pass or kept reversible (`superseded_at` is timestamp, not delete).
- **Memory access logs becoming a hot table** — insert-only, retention policy needed (e.g., truncate after 90 days).

## Success Metrics

After Phase 1: zero "the agent didn't remember what I just said on Telegram" reports.

After Phase 2: agent naturally references prior episodes by name/date in responses.

After Phase 3: agent successfully answers retrospective questions ("what did we decide about X?") without the user having to specify which conversation.

After Phase 4: every principal-mode response that draws on cross-principal data has a corresponding access log entry, and superseded preferences no longer appear in the prompt.
