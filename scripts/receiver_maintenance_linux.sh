#!/usr/bin/env bash
set -Eeuo pipefail

data_root="${HEALTH_TRACKER_HOME:-/var/lib/health-tracker}"
runtime_dir="${HEALTH_TRACKER_RUNTIME:-/opt/health-tracker/current}"
database_path="${HEALTH_RECEIVER_DB:-$data_root/health.sqlite3}"
backup_dir="${HEALTH_TRACKER_BACKUP_DIR:-$data_root/backups/automatic}"
key_path="${HEALTH_TRACKER_BACKUP_KEY:-$data_root/keys/backup-encryption.key}"
retention_days="${HEALTH_TRACKER_BACKUP_RETENTION_DAYS:-14}"

python_bin="$runtime_dir/.venv/bin/python"
crypto_script="$runtime_dir/scripts/secure_backup.py"

[[ -x "$python_bin" ]] || { printf 'Runtime Python is unavailable: %s\n' "$python_bin" >&2; exit 1; }
[[ -f "$crypto_script" ]] || { printf 'Backup encryption tool is unavailable: %s\n' "$crypto_script" >&2; exit 1; }
[[ -f "$database_path" ]] || { printf 'Database is unavailable: %s\n' "$database_path" >&2; exit 1; }
[[ -f "$key_path" ]] || { printf 'Backup key is unavailable: %s\n' "$key_path" >&2; exit 1; }
[[ "$retention_days" =~ ^[0-9]+$ ]] && (( retention_days >= 1 )) || {
    printf 'Invalid backup retention: %s\n' "$retention_days" >&2
    exit 2
}

install -d -m 700 "$backup_dir"
printf '[%s] Starting database maintenance\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
integrity="$(sqlite3 "$database_path" 'PRAGMA wal_checkpoint(PASSIVE); PRAGMA quick_check;' | tail -n 1)"
[[ "$integrity" == "ok" ]] || { printf 'SQLite quick_check failed: %s\n' "$integrity" >&2; exit 1; }

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/health-tracker-maintenance.XXXXXX")"
trap 'rm -rf -- "$temporary_dir"' EXIT
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
portable="$temporary_dir/health-tracker-$timestamp.zip"
encrypted="$backup_dir/health-tracker-$timestamp.htbk"

cd "$runtime_dir"
"$python_bin" -m receiver.cli v2-backup \
    --data-root "$data_root" \
    --database "$database_path" \
    --output "$portable" >/dev/null
"$python_bin" "$crypto_script" encrypt \
    --key "$key_path" --input "$portable" --output "$encrypted" >/dev/null
"$python_bin" "$crypto_script" verify \
    --key "$key_path" --input "$encrypted" >/dev/null
chmod 600 "$encrypted"
printf '[%s] Encrypted backup completed: %s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$encrypted"

# Only this exact automatic-backup filename pattern is eligible for deletion.
find "$backup_dir" -type f -name 'health-tracker-*.htbk' \
    -mtime "+$retention_days" -delete
printf '[%s] Maintenance completed\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
