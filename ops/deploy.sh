#!/usr/bin/env bash
set -euo pipefail

# Idempotent server-side deploy script for Bentley.
# Handles first-time bootstrap (env/service/directories) and normal redeploys.

APP_DIR="${APP_DIR:-/opt/bentley}"
BRANCH="${BRANCH:-main}"
SERVICE_NAME="${SERVICE_NAME:-bentley}"
SERVICE_USER="${SERVICE_USER:-bentley}"
SERVICE_GROUP="${SERVICE_GROUP:-$SERVICE_USER}"
ENV_FILE="${ENV_FILE:-/etc/bentley/bentley.env}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/${SERVICE_NAME}.service}"
SERVICE_TEMPLATE="${SERVICE_TEMPLATE:-$APP_DIR/ops/bentley.service.example}"
ENV_TEMPLATE="${ENV_TEMPLATE:-$APP_DIR/ops/bentley.env.example}"

run_root() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	else
		sudo "$@"
	fi
}

guard_env_file_target() {
	case "$ENV_FILE" in
		*/dev.example.env|dev.example.env)
			echo "ERROR: ENV_FILE must point to the server env file, not dev.example.env"
			echo "Use something like: ENV_FILE=/etc/bentley/bentley.env"
			exit 1
			;;
		*/.env|.env)
			echo "ERROR: ENV_FILE must not point to a local development .env file"
			echo "Use something like: ENV_FILE=/etc/bentley/bentley.env"
			exit 1
			;;
	esac
}

bootstrap_os_resources() {
	echo "==> Ensuring service user and directories"

	if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
		run_root useradd --system --create-home --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
	fi

	run_root mkdir -p "$APP_DIR" "$(dirname "$ENV_FILE")"
	run_root chown "$SERVICE_USER:$SERVICE_GROUP" "$APP_DIR"
	run_root chown root:root "$(dirname "$ENV_FILE")"
	run_root chmod 750 "$(dirname "$ENV_FILE")"
}

bootstrap_env_file() {
	if [ -f "$ENV_FILE" ]; then
		return
	fi

	echo "==> Creating missing env file from template"
	if [ ! -f "$ENV_TEMPLATE" ]; then
		echo "ERROR: env template not found: $ENV_TEMPLATE"
		exit 1
	fi

	run_root cp "$ENV_TEMPLATE" "$ENV_FILE"
	run_root chown root:root "$ENV_FILE"
	run_root chmod 600 "$ENV_FILE"

	echo "ERROR: Created $ENV_FILE from template."
	echo "Edit secrets and paths, then re-run deploy:"
	echo "  sudo nano $ENV_FILE"
	exit 1
}

bootstrap_service_file() {
	if [ -f "$SERVICE_FILE" ]; then
		return
	fi

	echo "==> Installing missing systemd service unit"
	if [ ! -f "$SERVICE_TEMPLATE" ]; then
		echo "ERROR: service template not found: $SERVICE_TEMPLATE"
		exit 1
	fi

	run_root cp "$SERVICE_TEMPLATE" "$SERVICE_FILE"
	run_root systemctl daemon-reload
	run_root systemctl enable "$SERVICE_NAME"
}

ensure_runtime_file() {
	file_path="$1"
	label="$2"

	if [ -z "$file_path" ]; then
		return
	fi

	if [ -f "$file_path" ]; then
		return
	fi

	echo "==> Creating missing $label file: $file_path"
	run_root mkdir -p "$(dirname "$file_path")"
	run_root touch "$file_path"

	run_root chown "$SERVICE_USER:$SERVICE_GROUP" "$(dirname "$file_path")" "$file_path"
	run_root chmod 750 "$(dirname "$file_path")"
	run_root chmod 640 "$file_path"
}

cd "$APP_DIR"

guard_env_file_target
bootstrap_os_resources
bootstrap_env_file
bootstrap_service_file

echo "==> Loading runtime environment from $ENV_FILE"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [ -z "${DATABASE_PATH:-}" ]; then
	echo "ERROR: DATABASE_PATH is not set in $ENV_FILE"
	exit 1
fi

if [[ "$DATABASE_PATH" != /* ]]; then
	echo "ERROR: DATABASE_PATH must be an absolute path, got: $DATABASE_PATH"
	exit 1
fi

DB_DIR="$(dirname "$DATABASE_PATH")"
echo "==> Ensuring database directory exists: $DB_DIR"
run_root mkdir -p "$DB_DIR"
run_root chown "$SERVICE_USER:$SERVICE_GROUP" "$DB_DIR"
run_root chmod 750 "$DB_DIR"

ensure_runtime_file "${SUSPICIOUS_TERMS_FILE_PATH:-}" "suspicious terms"
ensure_runtime_file "${NOTIFIERS_FILE_PATH:-}" "notifiers"
ensure_runtime_file "${SNIPERS_FILE_PATH:-}" "snipers"

echo "==> Updating source from origin/$BRANCH"
git fetch origin "$BRANCH"
git checkout "$BRANCH"
git pull --ff-only origin "$BRANCH"

echo "==> Building release"
export MIX_ENV=prod
mix deps.get --only prod
mix compile
mix release --overwrite

echo "==> Running database migrations"
mix ecto.migrate

echo "==> Restarting service: $SERVICE_NAME"
run_root systemctl restart "$SERVICE_NAME"
run_root systemctl status "$SERVICE_NAME" --no-pager

echo "==> Done"
