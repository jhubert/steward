# Cross-Conversation Continuity

## Problem

Agents lose continuity across channels. If a user texts the agent on Telegram and then emails 2 minutes later, the email-side agent has no idea what was just said. The intent is that an agent should behave like a human collaborator — phone call → text → email should feel like one continuous relationship.

## Root Cause

Conversations are isolated per `(user, agent, channel, external_thread_key)`. The only existing cross-conversation bridge is `Prompt::Assembler#thread_catalog` (`app/models/prompt/assembler.rb:204-238`), which surfaces sibling threads but only includes their content when they have a rolling `conversation_state.summary`.

Both background jobs that produce cross-thread context are **count-triggered**:

- `CompactConversationJob` runs only when `unsummarized_messages >= 20` (`Conversation::COMPACTION_THRESHOLD`).
- `ExtractMemoryJob` runs only when `unextracted_messages >= 10` (`Conversation::EXTRACTION_THRESHOLD`).

So short conversations (the common case for email threads) never get summarized or extracted, and the sibling appears in `thread_catalog` as a useless one-liner:

```
- email_subject (email, last active Mar 20)
```

Verified in production data — e.g. Marcus Chen has 7 short email threads with Jeremy, none summarized; Olivia has two 10-message email threads, neither summarized.

## Design — Three-Tier Continuity

Every message lands in at least one tier, so nothing is invisible:

| Tier | What | Trigger | Surfaces in prompt as |
|------|------|---------|------------------------|
| Short-term | Rolling cross-channel timeline of last N messages / last 24h | Live query at prompt-build time | `## Recent Activity With <user>` |
| Medium-term | `conversation_state.summary` per thread | 20 unsummarized msgs **OR** idle ≥ 6h with any unsummarized msgs | Existing `thread_catalog` |
| Long-term | `MemoryItem` extracted facts | 10 unextracted msgs **OR** idle ≥ 6h with any unextracted msgs | Existing `Memory::Retriever` (Layer D) |

The "phone call → text 2 min later" case lands in the short-term timeline (verbatim). The "10-message email thread from 3 days ago" case is handled by the idle-trigger compaction/extraction.

## Implementation

### 1. Short-term timeline in `Prompt::Assembler`

Replace (or augment) `thread_catalog` with a unified cross-channel timeline.

- Query: `Message.joins(:conversation).where(conversations: { user:, agent: }).where('messages.created_at > ?', 24.hours.ago).order(created_at: :desc).limit(30)`.
- Exclude messages from the current conversation (already in `build_history`).
- Render each as `[<channel> <local time>] <role>: <truncated content>`.
- Bound by `budgets['cross_channel']`.
- Skip section entirely if no qualifying messages.

Keep `thread_catalog` for long-running threads with summaries — the timeline catches recent activity, the catalog provides orientation for older threads with substantial history. Consider gating the catalog to threads with a summary only (drop the one-line stubs).

### 2. Idle-triggered compaction / extraction

Add to `Conversation`:

```ruby
IDLE_HOURS = 6

def stale_for_compaction?
  return false unless messages.any?
  last_unsummarized = messages.where('id > ?', state&.summarized_through_message_id || 0).order(:id).last
  return false unless last_unsummarized
  last_unsummarized.created_at < IDLE_HOURS.hours.ago
end

def stale_for_extraction?
  return false unless messages.any?
  last_unextracted = messages.where('id > ?', state&.extracted_through_message_id || 0).order(:id).last
  return false unless last_unextracted
  last_unextracted.created_at < IDLE_HOURS.hours.ago
end
```

Update existing predicates to OR-in the idle check:

```ruby
def needs_compaction?
  has_unsummarized_count? || stale_for_compaction?
end

def needs_extraction?
  has_unextracted_count? || stale_for_extraction?
end
```

### 3. Sibling sweep at end of `ProcessMessageJob`

No new scheduler. At the end of `ProcessMessageJob` (after `CompactConversationJob` / `ExtractMemoryJob` are enqueued for the current conversation), also enqueue them for stale siblings of the same `(user, agent)`:

```ruby
Conversation.where(user: conversation.user, agent: conversation.agent)
            .where.not(id: conversation.id)
            .find_each do |sib|
  CompactConversationJob.perform_later(sib.id) if sib.needs_compaction?
  ExtractMemoryJob.perform_later(sib.id) if sib.needs_extraction?
end
```

Cheap: sibling counts per user are small (single digits), the jobs themselves no-op when nothing to do, and they run on `:low_priority`.

### 4. Adjust the jobs

`CompactConversationJob` currently early-returns if `unsummarized.count < COMPACTION_THRESHOLD`. Change to run if either (a) count threshold met, or (b) `conversation.stale_for_compaction?`. Same for `ExtractMemoryJob`.

## Token Budget

Already have `budgets['cross_channel']` (default 1500). The timeline uses this; the catalog (if kept) shares the same budget. Default may need a small bump to ~2000 once both render.

## Migration / Backfill

One-shot rake task to compact + extract any conversation currently in the gap (has unsummarized/unextracted messages, last message older than 6h). Run once after deploy.

```bash
RAILS_ENV=production bin/rails runner /dev/stdin <<'RUBY'
Conversation.find_each do |c|
  CompactConversationJob.perform_later(c.id) if c.stale_for_compaction?
  ExtractMemoryJob.perform_later(c.id) if c.stale_for_extraction?
end
RUBY
```

## Testing

- Unit: `stale_for_compaction?` / `stale_for_extraction?` boundary cases (no messages, all summarized, idle but caught up, fresh but caught up).
- Unit: `Prompt::Assembler` timeline rendering with multi-channel fixtures, current-conversation exclusion, budget enforcement, 24h cutoff.
- Integration: simulate Telegram→email handoff in test, verify email-side prompt includes the Telegram exchange.

## Open Questions

- **Cutoff window**: 24h timeline + 6h idle compaction — both tunable per agent via `settings`?
- **Idle threshold per channel**: email threads naturally have longer gaps than chat. May want `EMAIL_IDLE_HOURS = 24`, `TELEGRAM_IDLE_HOURS = 6`. Start with a single value, tune if needed.
- **Background conversations**: timeline currently excludes `channel = "background"` (same as `thread_catalog`). Keep that — background activity has its own briefing section.
- **Cost**: extraction runs an LLM call per stale conversation per sweep. For users with many short threads (Cole Brennan-style daily check-ins) this could add up. Mitigation: extraction job advances the pointer even when it extracts nothing, so each conversation is processed at most once per "burst."
