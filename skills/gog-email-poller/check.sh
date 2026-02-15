#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/srv/steward/data/gog/${STEWARD_USER_ID}/email-poller-state.txt"
mkdir -p "$(dirname "$STATE_FILE")"
touch "$STATE_FILE"
last_id=$(cat "$STATE_FILE" 2>/dev/null || echo "")

result=$(gog gmail search "in:inbox is:unread" --limit 1 --json 2>/dev/null || echo "[]")
newest_id=$(echo "$result" | jq -r '.threads[0].id // empty' 2>/dev/null || echo "")

if [[ -n "$newest_id" && "$newest_id" != "$last_id" ]]; then
  echo "$newest_id" > "$STATE_FILE"
  echo "You have new unread email. Check your inbox."
fi
