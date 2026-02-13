#!/usr/bin/env bash
set -euo pipefail

# XDG_CONFIG_HOME and GOG_KEYRING_PASSWORD are injected by the executor
[ -z "${GOG_KEYRING_PASSWORD:-}" ] && { echo "ERROR: No Google credentials configured for this user" >&2; exit 1; }

COMMAND="$1"
read -ra CMD_ARGS <<< "$COMMAND"
exec gog --json --no-input "${CMD_ARGS[@]}"
