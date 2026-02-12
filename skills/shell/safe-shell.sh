#!/bin/bash
set -uo pipefail

# safe-shell.sh — Execute commands with safety guardrails.
# Blocks destructive operations and credential access.
# Not a security sandbox — a guardrail against accidental/hallucinated damage.

COMMAND="$1"

if [ -z "$COMMAND" ]; then
  echo "Usage: safe-shell.sh <command>" >&2
  exit 1
fi

# Normalize for matching (lowercase)
CMD_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')

# --- BLOCKED: Destructive system operations ---
declare -a BLOCKED=(
  # Filesystem destruction
  "rm -rf /"
  "rm -rf /*"
  "rm -rf ~"
  "rm -rf /home"
  "rm -rf /srv"
  "rm -rf /etc"
  "rm -rf /var"
  "rm -rf /usr"
  # Disk/device operations
  "mkfs"
  "dd if="
  "> /dev/"
  # System control
  "shutdown"
  "reboot"
  "halt"
  "init 0"
  "init 6"
  "poweroff"
  "systemctl stop"
  "systemctl disable"
  # Fork bomb patterns
  ":(){ :|:&};"
  # Process killing (init/systemd)
  "kill -9 1"
  "kill 1"
  "killall"
  "pkill"
)

for pattern in "${BLOCKED[@]}"; do
  if [[ "$CMD_LOWER" == *"$pattern"* ]]; then
    echo "BLOCKED: This command contains a restricted pattern ('$pattern'). If you believe this is needed, ask the user to run it manually." >&2
    exit 1
  fi
done

# --- BLOCKED: Credential/secret access ---
declare -a SECRETS_BLOCKED=(
  "credentials:show"
  "credentials:edit"
  "rails_master_key"
  "secret_key_base"
  "cat /etc/shadow"
  "cat /etc/gshadow"
  ".env"
  "master.key"
  "anthropic.api_key"
  "bot_token"
)

for pattern in "${SECRETS_BLOCKED[@]}"; do
  if [[ "$CMD_LOWER" == *"$pattern"* ]]; then
    echo "BLOCKED: This command may expose credentials or secrets ('$pattern'). Credential access is not allowed." >&2
    exit 1
  fi
done

# --- BLOCKED: Destructive git operations ---
declare -a GIT_BLOCKED=(
  "git push --force"
  "git push -f"
  "git reset --hard"
  "git clean -f"
  "git branch -D"
  "git checkout ."
  "git restore ."
)

for pattern in "${GIT_BLOCKED[@]}"; do
  if [[ "$CMD_LOWER" == *"$pattern"* ]]; then
    echo "BLOCKED: Destructive git operation ('$pattern'). Ask the user to run this manually if needed." >&2
    exit 1
  fi
done

# --- BLOCKED: Package management (system-level) ---
declare -a PKG_BLOCKED=(
  "apt install"
  "apt remove"
  "apt purge"
  "apt-get install"
  "apt-get remove"
  "dpkg -r"
  "dpkg --purge"
  "yum install"
  "yum remove"
)

for pattern in "${PKG_BLOCKED[@]}"; do
  if [[ "$CMD_LOWER" == *"$pattern"* ]]; then
    echo "BLOCKED: System package management ('$pattern'). Ask the user to handle package installation." >&2
    exit 1
  fi
done

# --- Execute the command ---
exec bash -c "$COMMAND"
