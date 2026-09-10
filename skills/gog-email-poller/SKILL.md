---
name: gog-email-poller
description: Check for new unread email using the gog CLI. Tracks state to only report genuinely new messages.
---

# Email Poller

Check for new unread email via the gog CLI. Uses a state file to track a fingerprint of the full unread-inbox state, so it only reports when that state has genuinely changed. Requires gog to be authenticated for the user.

Each report reflects real, current inbox state at the moment it ran — it is never a repeat of a prior firing. If two reports arrive close together, they are two distinct changes to the inbox (e.g. two separate emails a few minutes apart), not the same trigger firing twice. Don't describe firings as "duplicated" or speculate about the scheduler re-sending the same event — check the thread ID(s) in each report instead; they will differ.
