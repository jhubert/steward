---
name: gog-email-poller
description: Check for new unread email using the gog CLI. Tracks state to only report genuinely new messages.
---

# Email Poller

Check for new unread email via the gog CLI. Uses a state file to track the last-seen message ID, so it only reports genuinely new messages. Requires gog to be authenticated for the user.
