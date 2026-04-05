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
