#!/usr/bin/env bash
#
# update.sh — Pull latest code, migrate, and restart services
#
# Run on the droplet as the deploy user:
#   ./deploy/update.sh
#
set -euo pipefail

APP_DIR="/srv/steward"
RUBY_BIN="/home/deploy/.rubies/ruby-3.4.8/bin"
export PATH="$RUBY_BIN:$PATH"

cd "$APP_DIR"

echo "==> Pulling latest code"
git pull origin main

echo "==> Loading environment"
set -a; source "$APP_DIR/.env.production"; set +a

echo "==> Installing dependencies"
bundle install

echo "==> Running migrations"
bin/rails db:migrate

echo "==> Restarting services"
sudo systemctl restart steward steward-jobs steward-browser

echo ""
echo "  Update complete!"
echo "  Check status: sudo systemctl status steward steward-jobs steward-browser"
