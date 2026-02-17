# Steward Skill Conventions Reference

## Directory Structure

Skills live in `/srv/steward/skills/<skill-name>/`. Each skill directory contains:

| File | Required | Purpose |
|------|----------|---------|
| `SKILL.md` | Yes | Frontmatter (name, description) + markdown instructions |
| `tools.yml` | No | Tool definitions for the skill |
| `scripts/` | No | Executable scripts invoked by tools |
| `references/` | No | Detailed docs the agent can read for context |

## SKILL.md Frontmatter

The frontmatter block is YAML between `---` fences:

```yaml
---
name: skill-name        # Must match directory name, kebab-case
description: Short description for the skill catalog listing.
---
```

The body after frontmatter is markdown instructions loaded into the agent's prompt as Layer S.

## tools.yml Schema

```yaml
tools:
  - name: tool_name                    # Unique across the agent
    description: "What the tool does"  # Shown to the LLM
    input_schema:                      # JSON Schema (as YAML)
      type: object
      required:
        - param1
      properties:
        param1:
          type: string
          description: "Description for the LLM"
        param2:
          type: integer
          description: "Optional parameter"
    command_template: "python3 scripts/do_thing.py {param1} --count {param2}"
    working_directory: "/srv/steward/skills/my-skill"  # Optional, defaults to skill dir
    timeout_seconds: 30                                # Optional, defaults to 30
```

## How Tools Get Wired

1. `Skills::Registry` loads `tools.yml` at boot (or on reload)
2. `agent.enable_skill!(skill_name)` creates `AgentTool` records from the skill's tool definitions
3. `Tools::DefinitionBuilder` reads `agent.enabled_tools` and returns Anthropic-compatible schemas
4. `ProcessMessageJob` passes tools to the Anthropic API
5. When the LLM calls a tool, `Tools::Executor` runs the command via `Open3.capture3`

## Command Template Placeholders

- `{param}` in `command_template` is replaced with the LLM-provided value
- Parameters are passed as individual argv elements (safe from injection)
- The command is NOT run through a shell — it's split into argv arrays
- Scripts must be directly executable (`chmod +x` or invoked via interpreter like `python3`)

## Script Execution Model

- Scripts run via `Open3.capture3` with argv arrays (no shell expansion)
- Environment variables from `AgentTool.credentials` are injected at runtime
- Principal-specific env vars (GOG credentials) are also injected when available
- stdout is returned as tool result; stderr is included on non-zero exit
- Timeout kills the process after `timeout_seconds`

## Existing Skills for Reference

| Skill | Type | Description |
|-------|------|-------------|
| `web` | Tools | Web search and page reading via Jina AI |
| `gog` | Tools | Google Workspace operations |
| `pdf` | Tools (3) | PDF extraction, coordinate finding, form filling |
| `github` | Tools | GitHub operations via CLI |
| `scheduling` | Tools | Calendar/scheduling operations |
| `shell` | Tools | Shell command execution |
| `agent-management` | Tools | Platform agent/skill management |
| `example` | Instructions-only | Template for new skills |
| `system` | Instructions-only | System administration guidance |
