---
name: basecamp
description: Manage Basecamp projects, to-dos, cards, messages, chat, schedule, docs and files via the basecamp CLI.
---

# Basecamp

You have a `basecamp` tool that runs Basecamp CLI commands. Your Basecamp identity is injected automatically — never pass `--account`, `-a`, or `--profile`. Output is always JSON.

## If Basecamp isn't connected yet

If the tool reports no identity is configured, use the `basecamp_setup` tool: `check` to confirm, then `start` to get an authorization URL to send the user, then `complete` with the callback URL they paste back. The account connected there is the one all your Basecamp activity is attributed to, so connect the account the user tells you to.

## Usage

Pass the subcommand as the `command` parameter (everything after `basecamp`).

## Project scope

Most commands need a project: `--in <project_id>`. Get IDs from `projects list`, or from a URL with `url parse`.

Cross-project commands that need no `--in`: `reports assigned`, `reports overdue`, `reports schedule`, `assignments list`, `notifications list`, `search`. Several list commands also accept `--all-projects` (`todos`, `cards`, `messages`, `comments`, `files`), which returns the first 100 items unless you pass `--limit N` or `--all`.

## Quick reference

```
# Discovery
projects list                             # All projects
url parse "<basecamp url>"                # Extract account/project/recording IDs
search "authentication"                   # Search across projects
show <id> --in <project>                  # Show any item by ID

# To-dos
todos list --in <project>                  # To-dos in a project
todos list --all-projects --overdue        # Overdue everywhere (no --page)
todos create "Fix the bug" --in <project> --list <todolist_id>
todos create "Title" --in <project> --list <id> --due 2026-09-10 --assignee <person_id>
todos complete <todo_id> --in <project>
todos update <todo_id> --in <project> --description "..."
todolists list --in <project>

# Cards (Kanban)
cards list --in <project>
cards create "Title" --in <project>
cards move <card_id> --in <project>
cards done <card_id> --in <project>
cards columns --in <project>

# Messages & comments
messages list --in <project>
messages create "Subject" --in <project>
comments list <recording_id> --in <project>
comments create <recording_id> "Comment body" --in <project>

# Chat (Campfire)
chat post "Hello" --in <project>
chat messages --in <project>

# Schedule, docs, files, people
schedule entries --in <project>
docs list --in <project>
files list --in <project>
people list --in <project>
people pingable --in <project>            # Who you can @mention
reports assigned                           # Work assigned to you
notifications list
```

Use `<command> --help` to discover flags for any subcommand. `commands --json` lists the full catalog.

## Content and @mentions

Message bodies and comment content accept Markdown; the CLI converts it to HTML. To-do, doc, and card content is sent as-is — use plain text there.

For @mentions, prefer `[@Name](person:ID)` using an ID from `people pingable`. Bare `@Name` relies on fuzzy matching and can resolve to the wrong person.

## What you cannot do

The tool refuses these and returns an error explaining why:

- **Destructive actions** — `delete`, `trash`, `archive`, `remove` on anything. Not reversible from here. If something should be removed, say so and let a human do it.
- **Access and membership** — `people add`, `recordings visibility`.
- **Account and CLI administration** — `webhooks`, `accounts`, `profile`, `config`, `setup`, `migrate`, `upgrade`, `tools`, and `auth` (except `auth status`).

These are refusals by design, not bugs. Don't try to route around one — report it and move on.

## Important notes

- Every write you make is visible to everyone on the project and is attributed to your Basecamp identity. Treat posting a message, comment, or chat line as sending mail: get it right the first time. If a principal hasn't asked you to post something, don't.
- Reading is free — prefer looking things up over asking someone to look them up for you.
- Comments are flat. Reply to the parent recording, not to another comment.
- Errors come back as `{"ok": false, "code": ..., "retryable": ...}`. Retry only when `retryable` is true; otherwise report the error.
- The command string is split with POSIX shell-word rules and run directly — there is **no shell**. Pipes, redirects, `&&`, and `$'...'` quoting do not work and will be passed through as literal arguments. Use `--jq '<expr>'` instead of piping to `jq`. For multi-line content, put literal newlines inside a quoted argument.
- Reading content from stdin (`-`) is not available through this tool. Pass content inline.
- Long operations are subject to a 60-second timeout.
- If you get an identity or auth error, run `basecamp_setup` with action `check` and walk the user through connecting an account.
