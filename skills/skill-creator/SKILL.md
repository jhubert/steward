---
name: skill-creator
description: Create new skills for agents — codify repeated workflows into reusable capabilities with instructions, tools, and scripts.
---

# Skill Creator

You can create new skills for agents on the Steward platform using the `create_skill` tool. Skills teach agents new capabilities — a skill is a directory containing instructions (SKILL.md), optional tool definitions (tools.yml), and optional scripts.

## When to Create a Skill

Create a skill when:
- The user asks you to learn a new procedure or workflow
- A repeated multi-step process should be codified for reuse
- An agent needs a new tool backed by a script

Do NOT create a skill when:
- The task is a one-off request
- A simple memory/note would suffice
- An existing skill already covers the need (check first with the agent-management skill)

## Workflow

1. **Understand** — Ask the user what the skill should do, what inputs it needs, and what success looks like
2. **Plan** — Decide what the skill needs: instructions only, or instructions + tools + scripts
3. **Create** — Use the `create_skill` tool to write all files at once
4. **Enable** — Use the `enable_for` parameter to enable it on the target agent, or tell the user to enable it via agent-management
5. **Iterate** — If the skill needs changes, create it again with the same name (files are overwritten)

## Skill Anatomy

A skill is a directory under `skills/` containing:

```
skills/my-skill/
  SKILL.md          # Required: frontmatter + instructions
  tools.yml         # Optional: tool definitions
  scripts/          # Optional: executable scripts
  references/       # Optional: detailed docs the agent can read
```

### SKILL.md Format

```markdown
---
name: my-skill
description: One-line description for the skill catalog.
---

# Skill Title

Instructions for the agent. Keep this focused and actionable.

## When to Use
- Trigger conditions

## Instructions
1. Step-by-step workflow
```

### tools.yml Format

```yaml
tools:
  - name: tool_name
    description: "What the tool does"
    input_schema:
      type: object
      required:
        - param1
      properties:
        param1:
          type: string
          description: "What this parameter is"
    command_template: "python3 scripts/my_script.py {param1}"
    timeout_seconds: 30
```

## Guidelines

- **Skill names** must be kebab-case (e.g., `restaurant-search`, `daily-report`)
- **Keep SKILL.md lean** — put detailed reference material in `references/` subdirectory
- **Instructions-only skills** are fine — not every skill needs tools
- **Scripts** should be self-contained and handle their own errors
- **Command templates** use `{param}` placeholders that get substituted from LLM tool input
- Scripts run via `Open3` with argv arrays (no shell) — they must be directly executable

See `references/conventions.md` for the full Steward conventions reference.
