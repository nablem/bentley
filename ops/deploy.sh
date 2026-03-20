#!/usr/bin/env bash
set -euo pipefail

# Server-side deploy script for Bentley.
# Expected usage: run this on the Linux server where the repo is cloned.

APP_DIR="${APP_DIR:-/opt/bentley/app}"
BRANCH="${BRANCH:-main}"
SERVICE_NAME="${SERVICE_NAME:-bentley}"

cd "$APP_DIR"

echo "==> Updating source from origin/$BRANCH"
git fetch origin "$BRANCH"
git checkout "$BRANCH"
git pull --ff-only origin "$BRANCH"

echo "==> Building release"
export MIX_ENV=prod
mix deps.get --only prod
mix compile
mix release

echo "==> Running database migrations"
mix ecto.migrate

echo "==> Restarting service: $SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"
sudo systemctl status "$SERVICE_NAME" --no-pager

echo "==> Done"
