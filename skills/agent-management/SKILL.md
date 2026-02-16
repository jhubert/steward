---
name: agent-management
description: Manage Steward platform agents — list agents and skills, enable/disable skills, create new agents.
---

# Agent Management

You can manage agents on the Steward platform using the `manage_agents` tool.

## Available Actions

- **list_agents** — List all agents with their enabled skills
- **list_skills** — List the skill catalog (all available skills and their tools)
- **enable_skill** — Enable a skill for an agent (params: `{"agent": "AgentName", "skill": "skill_name"}`)
- **disable_skill** — Disable a skill for an agent (params: `{"agent": "AgentName", "skill": "skill_name"}`)
- **create_agent** — Create a new agent (params: `{"name": "AgentName", "system_prompt": "You are...", "telegram_bot_token": "optional"}`)

## Guidelines

- When creating a new agent, always ask the user for the agent's name, personality/system prompt, and which skills to enable.
- After creating an agent, enable the skills the user requested.
- If the user provides a Telegram bot token, include it. Otherwise the agent will use the default platform token.
- Use `list_skills` to show available skills before asking which to enable.
