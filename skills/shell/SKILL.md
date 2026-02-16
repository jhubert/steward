---
name: shell
description: Execute shell commands on the server with safety guardrails against destructive operations.
---

# Shell

Run arbitrary shell commands via bash with safety guardrails. Destructive operations (rm -rf, system shutdown, credential access, destructive git) are blocked. If a command is blocked, inform the user.
