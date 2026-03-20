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
AUTO_STASH_DIRTY_REPO="${AUTO_STASH_DIRTY_REPO:-1}"

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
		run_root useradd --system --no-create-home --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
	fi

	run_root mkdir -p "$APP_DIR" "$(dirname "$ENV_FILE")"
	run_root chown "$SERVICE_USER:$SERVICE_GROUP" "$APP_DIR"
	run_root chown "root:$SERVICE_GROUP" "$(dirname "$ENV_FILE")"
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

	echo "==> Created $ENV_FILE from template."
	echo "    Fill in secrets and paths, then re-run deploy:"
	echo "    nano $ENV_FILE"
	exit 0
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

ensure_service_file_command() {
	if [ ! -f "$SERVICE_FILE" ]; then
		return
	fi

	if run_root grep -q "bin/bentley foreground" "$SERVICE_FILE"; then
		echo "==> Updating service unit command: foreground -> start"
		run_root sed -i 's/bin\/bentley foreground/bin\/bentley start/' "$SERVICE_FILE"
		run_root systemctl daemon-reload
	fi
}

ensure_runtime_file() {
	file_path="$1"
	label="$2"
	created="0"

	if [ -z "$file_path" ]; then
		return
	fi

	run_root mkdir -p "$(dirname "$file_path")"

	if [ ! -f "$file_path" ]; then
		echo "==> Creating missing $label file: $file_path"
		created="1"
		case "$label" in
			notifiers)
				run_root sh -c "printf 'notifiers: []\n' > '$file_path'"
				;;
			snipers)
				run_root sh -c "printf 'snipers: []\n' > '$file_path'"
				;;
			*)
				run_root touch "$file_path"
				;;
		esac
	fi

	if [ "$created" = "0" ]; then
		case "$label" in
			notifiers)
				if ! run_root grep -Eq '^notifiers:' "$file_path"; then
					echo "==> Repairing invalid notifiers file: $file_path"
					run_root sh -c "printf 'notifiers: []\n' > '$file_path'"
				fi
				;;
			snipers)
				if ! run_root grep -Eq '^snipers:' "$file_path"; then
					echo "==> Repairing invalid snipers file: $file_path"
					run_root sh -c "printf 'snipers: []\n' > '$file_path'"
				fi
				;;
		esac
	fi

	run_root chown "root:$SERVICE_GROUP" "$(dirname "$file_path")"
	run_root chown "root:$SERVICE_GROUP" "$file_path"
	run_root chmod 750 "$(dirname "$file_path")"
	run_root chmod 640 "$file_path"
}

update_source() {
	echo "==> Updating source from origin/$BRANCH"
	git config --global --add safe.directory "$APP_DIR"
	git fetch origin "$BRANCH"
	git checkout "$BRANCH"

	if [ -n "$(git status --porcelain)" ]; then
		if [ "$AUTO_STASH_DIRTY_REPO" = "1" ]; then
			stash_name="deploy-auto-$(date +%s)"
			echo "==> Local git changes detected; stashing automatically ($stash_name)"
			git stash push --include-untracked -m "$stash_name" >/dev/null
		else
			echo "ERROR: local git changes detected. Commit/stash or set AUTO_STASH_DIRTY_REPO=1"
			exit 1
		fi
	fi

	git pull --ff-only origin "$BRANCH"
}

cd "$APP_DIR"

guard_env_file_target
bootstrap_os_resources
bootstrap_env_file
bootstrap_service_file
ensure_service_file_command

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

update_source

echo "==> Building release"
export MIX_ENV=prod
mix deps.get --only prod
mix compile
mix release --overwrite

echo "==> Running database migrations"
mix ecto.migrate

echo "==> Fixing sqlite file ownership"
run_root chown "$SERVICE_USER:$SERVICE_GROUP" "$DATABASE_PATH"
run_root chmod 640 "$DATABASE_PATH"
if [ -f "${DATABASE_PATH}-wal" ]; then
	run_root chown "$SERVICE_USER:$SERVICE_GROUP" "${DATABASE_PATH}-wal"
	run_root chmod 640 "${DATABASE_PATH}-wal"
fi
if [ -f "${DATABASE_PATH}-shm" ]; then
	run_root chown "$SERVICE_USER:$SERVICE_GROUP" "${DATABASE_PATH}-shm"
	run_root chmod 640 "${DATABASE_PATH}-shm"
fi

echo "==> Restarting service: $SERVICE_NAME"
run_root systemctl restart "$SERVICE_NAME"
run_root systemctl status "$SERVICE_NAME" --no-pager

echo "==> Done"
