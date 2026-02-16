#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/srv/steward/data/gog/${STEWARD_USER_ID}/email-poller-state.txt"
mkdir -p "$(dirname "$STATE_FILE")"
touch "$STATE_FILE"
last_fingerprint=$(cat "$STATE_FILE" 2>/dev/null || echo "")

# Fetch unread threads (limit 10 to catch activity beyond just the top thread)
result=$(gog gmail search "in:inbox is:unread" --limit 10 --json --no-input 2>&1)
if [[ $? -ne 0 ]]; then
  echo "Error checking email: $result" >&2
  exit 1
fi

# No results or empty → no unread email
thread_count=$(echo "$result" | jq '.threads | length' 2>/dev/null || echo "0")
if [[ "$thread_count" == "0" || "$thread_count" == "null" ]]; then
  : > "$STATE_FILE"
  exit 0
fi

# Fingerprint the full result — catches new threads AND new replies
# (replies change the thread's snippet and message list in the search output)
fingerprint=$(echo "$result" | md5sum | cut -d' ' -f1)

if [[ "$fingerprint" != "$last_fingerprint" ]]; then
  echo "$fingerprint" > "$STATE_FILE"

  # Output a summary of unread threads so the agent has context
  echo "You have ${thread_count} unread email thread(s):"
  echo ""
  echo "$result" | jq -r '.threads[] | "- [\(.id)] \(.subject) (from: \(.from), \(.messageCount) message(s), \(.date))"'
  echo ""
  echo "IMPORTANT: You MUST read each thread before acting on it. Do NOT assume you know what it says."
  echo "For each thread above:"
  echo "  1. READ the full thread: gmail thread get <threadId> --full"
  echo "  2. Reply if the latest message needs a response"
  echo "  3. Archive after handling: gmail thread modify <threadId> --remove INBOX,UNREAD"
fi
