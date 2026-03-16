#!/usr/bin/env bash
#
# setup.sh — Provision a fresh Ubuntu 24.04 droplet for Steward
#
# This script runs as root on the droplet. It expects these env vars:
#   DOMAIN           (required) — e.g., myagent.example.com
#   ANTHROPIC_API_KEY (required)
#   REPO_URL         (required) — git clone URL
#   OPENAI_API_KEY   (optional)
#   TELEGRAM_BOT_TOKEN (optional)
#
set -euo pipefail

# ---------- Validate inputs ----------
if [[ -z "${DOMAIN:-}" ]]; then echo "ERROR: DOMAIN is required"; exit 1; fi
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then echo "ERROR: ANTHROPIC_API_KEY is required"; exit 1; fi
if [[ -z "${REPO_URL:-}" ]]; then echo "ERROR: REPO_URL is required"; exit 1; fi

RUBY_VERSION="3.4.8"
NODE_MAJOR="22"
DEPLOY_USER="deploy"
APP_DIR="/srv/steward"

step() { echo ""; echo "==> $*"; }

# ---------- 1. System packages ----------
step "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  build-essential git curl wget \
  libpq-dev libssl-dev libreadline-dev zlib1g-dev libyaml-dev \
  libffi-dev libgmp-dev autoconf bison rustc \
  nginx certbot python3-certbot-nginx \
  ufw jq \
  # Chromium dependencies
  libnss3 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libdrm2 \
  libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 libgbm1 \
  libpango-1.0-0 libasound2t64 libxshmfence1 \
  chromium-browser
echo "  done"

# ---------- 2. PostgreSQL 17 + pgvector ----------
step "Setting up PostgreSQL 17"
if ! command -v pg_isready &>/dev/null || ! pg_lsclusters 2>/dev/null | grep -q "17"; then
  # Add PostgreSQL apt repo
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
  apt-get install -y -qq postgresql-17 postgresql-17-pgvector
fi

# Ensure PostgreSQL is running
systemctl enable postgresql
systemctl start postgresql

# Create deploy role + databases (idempotent)
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='$DEPLOY_USER'" | grep -q 1 \
  || sudo -u postgres createuser --superuser "$DEPLOY_USER"

for db in steward_production steward_production_cache steward_production_queue; do
  sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1 \
    || sudo -u postgres createdb -O "$DEPLOY_USER" "$db"
done

# Enable pgvector extension
sudo -u postgres psql -d steward_production -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>/dev/null || true
echo "  done"

# ---------- 3. Create deploy user ----------
step "Creating deploy user"
if ! id "$DEPLOY_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$DEPLOY_USER"
fi

# Copy SSH keys from root so we can SSH as deploy
mkdir -p /home/$DEPLOY_USER/.ssh
cp /root/.ssh/authorized_keys /home/$DEPLOY_USER/.ssh/authorized_keys
chown -R $DEPLOY_USER:$DEPLOY_USER /home/$DEPLOY_USER/.ssh
chmod 700 /home/$DEPLOY_USER/.ssh
chmod 600 /home/$DEPLOY_USER/.ssh/authorized_keys

# Sudoers for service restarts (no password)
cat > /etc/sudoers.d/steward <<SUDOERS
$DEPLOY_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart steward, /usr/bin/systemctl restart steward-jobs, /usr/bin/systemctl restart steward-browser, /usr/bin/systemctl restart steward steward-jobs steward-browser, /usr/bin/certbot *
SUDOERS
chmod 440 /etc/sudoers.d/steward
echo "  done"

# ---------- 4. Ruby ----------
step "Installing Ruby $RUBY_VERSION (this takes a few minutes)"
if [[ ! -x "/home/$DEPLOY_USER/.rubies/ruby-$RUBY_VERSION/bin/ruby" ]]; then
  # Install ruby-install
  if ! command -v ruby-install &>/dev/null; then
    RUBY_INSTALL_VERSION="0.9.4"
    cd /tmp
    wget -q "https://github.com/postmodern/ruby-install/releases/download/v${RUBY_INSTALL_VERSION}/ruby-install-${RUBY_INSTALL_VERSION}.tar.gz"
    tar -xzf "ruby-install-${RUBY_INSTALL_VERSION}.tar.gz"
    cd "ruby-install-${RUBY_INSTALL_VERSION}"
    make install
    cd /
  fi

  # Install Ruby as deploy user
  sudo -u "$DEPLOY_USER" ruby-install --install-dir "/home/$DEPLOY_USER/.rubies/ruby-$RUBY_VERSION" ruby "$RUBY_VERSION" -- --disable-install-doc
fi

RUBY_BIN="/home/$DEPLOY_USER/.rubies/ruby-$RUBY_VERSION/bin"

# Add Ruby to deploy user's PATH
if ! grep -q "rubies/ruby-$RUBY_VERSION" /home/$DEPLOY_USER/.bashrc 2>/dev/null; then
  echo "export PATH=\"$RUBY_BIN:\$PATH\"" >> /home/$DEPLOY_USER/.bashrc
fi
echo "  done"

# ---------- 5. Node.js ----------
step "Installing Node.js $NODE_MAJOR"
if ! command -v node &>/dev/null || ! node -v 2>/dev/null | grep -q "v${NODE_MAJOR}"; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y -qq nodejs
fi
echo "  done"

# ---------- 6. Clone repo + install deps ----------
step "Cloning repo and installing dependencies"

# Create app directory
mkdir -p "$APP_DIR"
chown $DEPLOY_USER:$DEPLOY_USER "$APP_DIR"

if [[ ! -d "$APP_DIR/.git" ]]; then
  sudo -u "$DEPLOY_USER" git clone "$REPO_URL" "$APP_DIR"
else
  cd "$APP_DIR"
  sudo -u "$DEPLOY_USER" git pull origin main
fi

cd "$APP_DIR"

# Bundle install
sudo -u "$DEPLOY_USER" bash -c "export PATH=$RUBY_BIN:\$PATH && cd $APP_DIR && bundle install"

# Node deps for browser skill (if present)
if [[ -f "$APP_DIR/skills/browser/package.json" ]]; then
  cd "$APP_DIR/skills/browser"
  sudo -u "$DEPLOY_USER" npm install
  # Install Playwright's Chromium
  sudo -u "$DEPLOY_USER" npx playwright install chromium 2>/dev/null || true
fi

# Create log directory
mkdir -p "$APP_DIR/log"
chown $DEPLOY_USER:$DEPLOY_USER "$APP_DIR/log"
echo "  done"

# ---------- 7. Generate credentials + env file ----------
step "Configuring environment"

# Generate encryption keys
SECRET_KEY_BASE=$(sudo -u "$DEPLOY_USER" bash -c "export PATH=$RUBY_BIN:\$PATH && ruby -rsecurerandom -e 'puts SecureRandom.hex(64)'")
AR_PRIMARY_KEY=$(sudo -u "$DEPLOY_USER" bash -c "export PATH=$RUBY_BIN:\$PATH && ruby -rsecurerandom -e 'puts SecureRandom.hex(16)'")
AR_DETERMINISTIC_KEY=$(sudo -u "$DEPLOY_USER" bash -c "export PATH=$RUBY_BIN:\$PATH && ruby -rsecurerandom -e 'puts SecureRandom.hex(16)'")
AR_KEY_DERIVATION_SALT=$(sudo -u "$DEPLOY_USER" bash -c "export PATH=$RUBY_BIN:\$PATH && ruby -rsecurerandom -e 'puts SecureRandom.hex(16)'")

cat > "$APP_DIR/.env.production" <<ENV
# Steward environment — generated by setup.sh
RAILS_ENV=production
PORT=5000

# Domain
STEWARD_DOMAIN=$DOMAIN

# SSL — set to 1 until certbot is configured, then remove this line
DISABLE_SSL=1

# Secrets
SECRET_KEY_BASE=$SECRET_KEY_BASE

# Active Record Encryption
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=$AR_PRIMARY_KEY
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=$AR_DETERMINISTIC_KEY
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=$AR_KEY_DERIVATION_SALT

# API Keys
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
ENV

# Add optional keys
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  echo "OPENAI_API_KEY=$OPENAI_API_KEY" >> "$APP_DIR/.env.production"
fi
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  echo "TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN" >> "$APP_DIR/.env.production"
fi

# Add placeholders for optional services
cat >> "$APP_DIR/.env.production" <<'ENV'

# Postmark (optional — for email support)
# POSTMARK_SERVER_TOKEN=
# POSTMARK_EMAIL_DOMAIN=
ENV

chown $DEPLOY_USER:$DEPLOY_USER "$APP_DIR/.env.production"
chmod 600 "$APP_DIR/.env.production"
echo "  done"

# ---------- 8. Database setup ----------
step "Setting up database"

# Source the env file and run db:prepare
sudo -u "$DEPLOY_USER" bash -c "
  export PATH=$RUBY_BIN:\$PATH
  set -a; source $APP_DIR/.env.production; set +a
  cd $APP_DIR
  bin/rails db:prepare
  bin/rails db:seed
"
echo "  done"

# ---------- 9. Systemd services ----------
step "Installing systemd services"

cp /tmp/deploy/templates/steward.service /etc/systemd/system/steward.service
cp /tmp/deploy/templates/steward-jobs.service /etc/systemd/system/steward-jobs.service
cp /tmp/deploy/templates/steward-browser.service /etc/systemd/system/steward-browser.service

systemctl daemon-reload
systemctl enable steward steward-jobs steward-browser
systemctl start steward steward-jobs

# Only start browser service if the skill exists
if [[ -f "$APP_DIR/skills/browser/scripts/browser-server.js" ]]; then
  systemctl start steward-browser
fi
echo "  done"

# ---------- 10. Nginx ----------
step "Configuring Nginx"

# Generate site config from template
sed "s/__DOMAIN__/$DOMAIN/g" /tmp/deploy/templates/steward-nginx.conf \
  > /etc/nginx/sites-available/steward

# Enable the site
ln -sf /etc/nginx/sites-available/steward /etc/nginx/sites-enabled/steward
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx
echo "  done"

# ---------- 11. Firewall ----------
step "Configuring firewall"
ufw --force reset >/dev/null 2>&1
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
echo "  done"

# ---------- 12. Cleanup ----------
rm -rf /tmp/deploy

# ---------- Done ----------
echo ""
echo "=========================================="
echo "  Setup complete!"
echo "=========================================="
echo ""
echo "  Services: steward, steward-jobs, steward-browser"
echo "  App dir:  $APP_DIR"
echo "  Env file: $APP_DIR/.env.production"
echo "  Logs:     $APP_DIR/log/"
echo ""
