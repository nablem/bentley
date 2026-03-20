#!/usr/bin/env bash
set -euo pipefail

# Push local notifiers.yaml, snipers.yaml, and suspicious_terms.txt to the
# server and trigger a live reload — no release rebuild or restart required.
#
# Usage:
#   ./ops/sync-config.sh user@your-server
#
# Optional overrides (environment variables):
#   SERVER_CONFIG_DIR  — destination directory on server (default: /etc/bentley)
#   APP_RELEASE_BIN    — path to the release binary on server
#                        (default: /opt/bentley/_build/prod/rel/bentley/bin/bentley)
#   SERVICE_GROUP      — group owning the config files (default: bentley)

SERVER="${1:?Usage: $0 user@your-server}"

SERVER_CONFIG_DIR="${SERVER_CONFIG_DIR:-/etc/bentley}"
APP_RELEASE_BIN="${APP_RELEASE_BIN:-/opt/bentley/_build/prod/rel/bentley/bin/bentley}"
SERVICE_GROUP="${SERVICE_GROUP:-bentley}"

echo "==> Syncing config files to $SERVER:$SERVER_CONFIG_DIR"
rsync -avz ./notifiers.yaml ./snipers.yaml ./suspicious_terms.txt "$SERVER:/tmp/"

echo "==> Installing files and reloading on server"
ssh "$SERVER" bash -s -- "$SERVER_CONFIG_DIR" "$APP_RELEASE_BIN" "$SERVICE_GROUP" << 'REMOTE'
CONFIG_DIR="$1"
BIN="$2"
GROUP="$3"

sudo install -o root -g "$GROUP" -m 640 /tmp/notifiers.yaml        "$CONFIG_DIR/notifiers.yaml"
sudo install -o root -g "$GROUP" -m 640 /tmp/snipers.yaml          "$CONFIG_DIR/snipers.yaml"
sudo install -o root -g "$GROUP" -m 640 /tmp/suspicious_terms.txt  "$CONFIG_DIR/suspicious_terms.txt"

"$BIN" rpc "Bentley.Notifiers.reload()"
"$BIN" rpc "Bentley.Snipers.reload()"
"$BIN" rpc "Bentley.SuspiciousTermsCache.reload()"
REMOTE

echo "==> Done"
