#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
APP_NAME="bentley"
# This is where your live binary will live
DEPLOY_DIR="/opt/bentley"
ENV_FILE="/etc/bentley/bentley.env"

echo "==> Pulling latest code"
git fetch origin main
git checkout main
git pull --ff-only origin main

echo "==> Loading $ENV_FILE"
if [ -f "$ENV_FILE" ]; then
    set -a && source "$ENV_FILE" && set +a
fi

echo "==> Building Release"
export MIX_ENV=prod
mix deps.get --only prod
mix compile
mix release --overwrite

echo "==> Migrating Database"
mix ecto.migrate

echo "==> Syncing build to $DEPLOY_DIR"
# This takes the output of 'mix release' and puts it exactly where you want it
sudo mkdir -p "$DEPLOY_DIR"
sudo rsync -av --delete "_build/prod/rel/$APP_NAME/" "$DEPLOY_DIR/"

echo "==> Restarting Service"
sudo systemctl restart "$APP_NAME"
sudo systemctl status "$APP_NAME" --no-pager