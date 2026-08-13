---
name: github
description: "GitHub integration via gh CLI"
---

# GitHub Skill

Access GitHub via the `gh` CLI tool. Use the `github` tool to run any `gh` subcommand.

## Usage

Pass the full subcommand string (without the `gh` prefix) as the `command` parameter.

### Examples

- **List open PRs:** `pr list --repo org/repo`
- **View a PR:** `pr view 42 --repo org/repo`
- **Create an issue:** `issue create --repo org/repo --title "Bug" --body "Details"`
- **List issues:** `issue list --repo org/repo --state open`
- **View a repo:** `repo view org/repo`
- **List releases:** `release list --repo org/repo`
- **API call:** `api repos/org/repo/pulls --jq '.[].title'`
- **Search code:** `search code "TODO" --repo org/repo`

## Notes

- Always use `--repo owner/repo` to specify the repository.
- The tool authenticates via a pre-configured token — no login is needed.
- Output may be truncated for very large results. Use `--limit` or `--jq` to filter.
- When using `--json`, field names are plural where applicable: `assignees` (not `assignee`), `labels`, `reviewers`. If unsure of a field name, run the command without `--json` first, or pass `--help` to list valid fields.
- **No shell — pipes/redirects don't work.** Your command string is passed directly as arguments to `gh`, not through a shell. `| base64 -d`, `| jq`, `| head`, `> file`, `&&` etc. will NOT work and produce confusing `gh` flag-parsing errors (e.g. "unknown shorthand flag: 'd' in -d"). Use `gh`'s own filtering instead: `--jq` for JSON extraction, `-q` for templates. To read a file's contents from a repo, use `api repos/org/repo/contents/path/to/file --jq '.content'` — this returns base64 text as the tool result; decode it yourself from that text rather than trying to pipe it. Note the `shell` tool does not have GitHub authentication, so `gh` commands only work through this `github` tool.
