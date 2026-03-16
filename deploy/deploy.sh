#!/usr/bin/env bash
#
# deploy.sh — Create a DigitalOcean droplet and provision Steward
#
# Run this locally:
#   ./deploy/deploy.sh
#
# Prerequisites:
#   - doctl (DigitalOcean CLI) installed and authenticated
#   - SSH key added to your DO account
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_URL="https://github.com/boardwiseco/steward.git"
DROPLET_NAME="steward"

# ---------- Colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}  $*${NC}"; }
ok()    { echo -e "${GREEN}  ✓ $*${NC}"; }
warn()  { echo -e "${YELLOW}  ! $*${NC}"; }
err()   { echo -e "${RED}  ✗ $*${NC}" >&2; }
header(){ echo -e "\n${BOLD}$*${NC}"; }

# ---------- Prerequisites ----------
header "Steward Deploy"
echo "  =============="
echo ""

if ! command -v doctl &>/dev/null; then
  err "doctl not found. Install it: https://docs.digitalocean.com/reference/doctl/how-to/install/"
  exit 1
fi

if ! doctl account get &>/dev/null; then
  err "doctl not authenticated. Run: doctl auth init"
  exit 1
fi

ok "doctl authenticated"

# ---------- Configuration ----------
header "Configuration"

read -rp "  Domain (required): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
  err "Domain is required"
  exit 1
fi

read -rp "  Anthropic API key (required): " ANTHROPIC_API_KEY
if [[ -z "$ANTHROPIC_API_KEY" ]]; then
  err "Anthropic API key is required"
  exit 1
fi

read -rp "  OpenAI API key (optional, press Enter to skip): " OPENAI_API_KEY

read -rp "  Telegram bot token (optional, press Enter to skip): " TELEGRAM_BOT_TOKEN

read -rp "  Region [nyc1]: " DO_REGION
DO_REGION="${DO_REGION:-nyc1}"

read -rp "  Droplet size [s-2vcpu-4gb]: " DO_SIZE
DO_SIZE="${DO_SIZE:-s-2vcpu-4gb}"

# ---------- SSH Key Selection ----------
header "SSH Key"
echo ""
info "Available SSH keys:"
doctl compute ssh-key list --format ID,Name,FingerPrint --no-header | while IFS= read -r line; do
  echo "    $line"
done
echo ""
read -rp "  SSH key ID (or name): " SSH_KEY_INPUT

if [[ -z "$SSH_KEY_INPUT" ]]; then
  err "SSH key is required"
  exit 1
fi

# Validate the SSH key exists
if ! doctl compute ssh-key get "$SSH_KEY_INPUT" &>/dev/null; then
  err "SSH key '$SSH_KEY_INPUT' not found"
  exit 1
fi
ok "SSH key validated"

# ---------- Create Droplet ----------
header "Creating Droplet"
info "Name: $DROPLET_NAME | Region: $DO_REGION | Size: $DO_SIZE"

DROPLET_ID=$(doctl compute droplet create "$DROPLET_NAME" \
  --region "$DO_REGION" \
  --size "$DO_SIZE" \
  --image ubuntu-24-04-x64 \
  --ssh-keys "$SSH_KEY_INPUT" \
  --tag-name steward \
  --format ID \
  --no-header \
  --wait)

ok "Droplet created (ID: $DROPLET_ID)"

# Get the IP
DROPLET_IP=$(doctl compute droplet get "$DROPLET_ID" --format PublicIPv4 --no-header)
ok "IP: $DROPLET_IP"

# ---------- Wait for SSH ----------
info "Waiting for SSH..."
for i in $(seq 1 60); do
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes "root@$DROPLET_IP" true 2>/dev/null; then
    break
  fi
  if [[ $i -eq 60 ]]; then
    err "SSH not ready after 5 minutes"
    exit 1
  fi
  sleep 5
done
ok "SSH ready"

# ---------- Copy deploy files ----------
info "Copying deploy scripts..."
scp -o StrictHostKeyChecking=no -r "$SCRIPT_DIR" "root@$DROPLET_IP:/tmp/deploy"
ok "Files copied"

# ---------- Run setup ----------
header "Running setup (~10 minutes)"
info "This will install all dependencies and configure Steward."
echo ""

# Build env vars to pass (never written to local disk)
SETUP_ENV="DOMAIN=$DOMAIN"
SETUP_ENV="$SETUP_ENV ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"
SETUP_ENV="$SETUP_ENV REPO_URL=$REPO_URL"
[[ -n "${OPENAI_API_KEY:-}" ]] && SETUP_ENV="$SETUP_ENV OPENAI_API_KEY=$OPENAI_API_KEY"
[[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] && SETUP_ENV="$SETUP_ENV TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN"

ssh -o StrictHostKeyChecking=no "root@$DROPLET_IP" \
  "$SETUP_ENV bash /tmp/deploy/setup.sh"

# ---------- Done ----------
echo ""
echo -e "${GREEN}${BOLD}  =========================================="
echo "   Steward is running!"
echo -e "  ==========================================${NC}"
echo ""
info "IP: $DROPLET_IP"
echo ""
header "Next steps:"
echo "  1. Point DNS: $DOMAIN → $DROPLET_IP"
echo "  2. Enable SSL:"
echo "     ssh deploy@$DROPLET_IP 'sudo certbot --nginx -d $DOMAIN --agree-tos --non-interactive -m admin@$DOMAIN'"
echo "  3. SSH in: ssh deploy@$DROPLET_IP"
echo "  4. Set up Telegram webhook (after SSL):"
echo "     ssh deploy@$DROPLET_IP 'cd /srv/steward && RAILS_ENV=production bin/rails telegram:set_all_webhooks'"
echo ""
