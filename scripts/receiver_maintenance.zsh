#!/bin/zsh
set -euo pipefail

support_dir="${HEALTH_TRACKER_HOME:-$HOME/Library/Application Support/HealthTracker}"
runtime_dir="${HEALTH_TRACKER_RUNTIME:-$support_dir/runtime/current}"
database_path="${HEALTH_RECEIVER_DB:-$support_dir/health.sqlite3}"
backup_dir="${HEALTH_TRACKER_BACKUP_DIR:-$support_dir/backups/automatic}"
key_path="${HEALTH_TRACKER_BACKUP_KEY:-$support_dir/keys/backup-encryption.key}"
log_dir="${HEALTH_TRACKER_LOG_DIR:-$HOME/Library/Logs/HealthTracker}"
retention_days="${HEALTH_TRACKER_BACKUP_RETENTION_DAYS:-14}"
max_log_bytes="${HEALTH_TRACKER_MAX_LOG_BYTES:-10485760}"
launch_domain="${HEALTH_TRACKER_LAUNCH_DOMAIN:-gui/$(id -u)}"
receiver_label="${HEALTH_TRACKER_RECEIVER_LABEL:-com.longfeihao.health-receiver}"
owner_name="${HEALTH_TRACKER_OWNER:-}"
owner_group="${HEALTH_TRACKER_OWNER_GROUP:-staff}"

python_bin="$runtime_dir/.venv/bin/python"
crypto_script="$runtime_dir/scripts/secure_backup.py"
[[ -x "$python_bin" ]] || { print -u2 -- "runtime Python 不可用：$python_bin"; exit 1; }
[[ -f "$crypto_script" ]] || { print -u2 -- "备份加密工具不存在：$crypto_script"; exit 1; }
[[ -f "$key_path" ]] || { print -u2 -- "备份密钥不存在：$key_path"; exit 1; }
[[ "$retention_days" == <-> && "$retention_days" -ge 1 ]] || { print -u2 -- "无效保留天数"; exit 1; }

mkdir -p "$backup_dir" "$log_dir"
chmod 700 "$backup_dir"

print -- "[$(date '+%Y-%m-%dT%H:%M:%S%z')] 开始数据库维护"
integrity="$(sqlite3 "$database_path" 'PRAGMA wal_checkpoint(PASSIVE); PRAGMA quick_check;' | tail -1)"
[[ "$integrity" == "ok" ]] || { print -u2 -- "SQLite quick_check 失败：$integrity"; exit 1; }

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/health-tracker-maintenance.XXXXXX")"
trap 'rm -rf -- "$temporary_dir"' EXIT
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
portable="$temporary_dir/health-tracker-$timestamp.zip"
encrypted="$backup_dir/health-tracker-$timestamp.htbk"

"$python_bin" -m receiver.cli v2-backup \
    --data-root "$support_dir" \
    --database "$database_path" \
    --output "$portable" >/dev/null
"$python_bin" "$crypto_script" encrypt --key "$key_path" --input "$portable" --output "$encrypted" >/dev/null
"$python_bin" "$crypto_script" verify --key "$key_path" --input "$encrypted" >/dev/null
if [[ -n "$owner_name" && "$(id -u)" -eq 0 ]]; then
    chown "$owner_name:$owner_group" "$encrypted"
fi
print -- "[$(date '+%Y-%m-%dT%H:%M:%S%z')] 加密备份完成：$encrypted"

# Only encrypted automatic backups with our exact filename pattern are eligible.
find "$backup_dir" -type f -name 'health-tracker-*.htbk' -mtime "+$retention_days" -delete

rotate_file() {
    local target="$1"
    [[ -f "$target" ]] || return 1
    local size="$(stat -f '%z' "$target")"
    (( size >= max_log_bytes )) || return 1
    rm -f -- "$target.5"
    local index
    for index in 4 3 2 1; do
        [[ -f "$target.$index" ]] && mv -- "$target.$index" "$target.$((index + 1))"
    done
    mv -- "$target" "$target.1"
    return 0
}

receiver_rotated=0
rotate_file "$log_dir/receiver.log" && receiver_rotated=1 || true
rotate_file "$log_dir/receiver-error.log" && receiver_rotated=1 || true
rotate_file "$log_dir/daily-export.log" || true
rotate_file "$log_dir/daily-export-error.log" || true
rotate_file "$log_dir/watchdog.log" || true
rotate_file "$log_dir/watchdog-error.log" || true
rotate_file "$log_dir/maintenance.log" || true
rotate_file "$log_dir/maintenance-error.log" || true

if (( receiver_rotated )); then
    launchctl kickstart -k "$launch_domain/$receiver_label"
    print -- "[$(date '+%Y-%m-%dT%H:%M:%S%z')] Receiver 日志已轮转并重新打开"
fi

print -- "[$(date '+%Y-%m-%dT%H:%M:%S%z')] 维护完成"
