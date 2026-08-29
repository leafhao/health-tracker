#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_dir="$(cd -- "$script_dir/.." && pwd -P)"
command_name="${1:-check}"
if (( $# > 0 )); then shift; fi

dry_run=0
open_firewall=0
cleanup_dir=""
cleanup() {
    if [[ -n "$cleanup_dir" && -d "$cleanup_dir" ]]; then
        rm -rf -- "$cleanup_dir"
    fi
}
trap cleanup EXIT
while (( $# )); do
    case "$1" in
        --dry-run) dry_run=1; shift ;;
        --open-firewall) open_firewall=1; shift ;;
        -h|--help) command_name="help"; shift ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

service_user="${HEALTH_TRACKER_SERVICE_USER:-healthtracker}"
data_root="${HEALTH_TRACKER_HOME:-/var/lib/health-tracker}"
runtime_root="${HEALTH_TRACKER_RUNTIME_ROOT:-/opt/health-tracker}"
environment_dir="${HEALTH_TRACKER_ENVIRONMENT_DIR:-/etc/health-tracker}"
environment_file="$environment_dir/receiver.env"
database_path="$data_root/health.sqlite3"
export_dir="$data_root/exports"
backup_dir="$data_root/backups/automatic"
key_path="$data_root/keys/backup-encryption.key"
unit_dir="/etc/systemd/system"
receiver_unit="health-tracker-receiver.service"
units=(
    health-tracker-receiver.service
    health-tracker-normalizer.service
    health-tracker-cloud-relay.service
    health-tracker-daily-export.service health-tracker-daily-export.timer
    health-tracker-watchdog.service health-tracker-watchdog.timer
    health-tracker-maintenance.service health-tracker-maintenance.timer
)

usage() {
    cat <<'EOF'
HealthTracker Linux one-click service configuration (systemd)

Usage:
  ./scripts/configure_receiver_linux.sh check
  ./scripts/configure_receiver_linux.sh install [--open-firewall] [--dry-run]
  ./scripts/configure_receiver_linux.sh update [--dry-run]
  ./scripts/configure_receiver_linux.sh backup-now

Defaults:
  Runtime releases: /opt/health-tracker/releases
  Persistent data:  /var/lib/health-tracker
  Service account:   healthtracker

The installer supports systemd Linux. Avahi provides automatic iPhone discovery;
manual LAN pairing remains available when Avahi is absent. --open-firewall opens
TCP 8787 using firewalld or UFW when either firewall is active.
EOF
}

is_linux() {
    [[ "$(uname -s)" == "Linux" ]]
}

require_linux() {
    is_linux || { printf 'This installer only supports Linux. Use configure_receiver_macos.zsh on macOS.\n' >&2; exit 1; }
    command -v systemctl >/dev/null 2>&1 || { printf 'systemd/systemctl is required.\n' >&2; exit 1; }
    [[ -d /run/systemd/system ]] || { printf 'systemd is not PID 1 on this host.\n' >&2; exit 1; }
}

find_python() {
    local candidate
    for candidate in python3.13 python3.12 python3.11 python3; do
        command -v "$candidate" >/dev/null 2>&1 || continue
        candidate="$(command -v "$candidate")"
        if "$candidate" -c 'import sys; raise SystemExit(sys.version_info < (3, 11))'; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

validate_targets() {
    case "$data_root" in
        /|/var|/var/lib|/home|/root) printf 'Refusing unsafe HEALTH_TRACKER_HOME: %s\n' "$data_root" >&2; exit 2 ;;
    esac
    case "$runtime_root" in
        /|/opt|/usr|/usr/local) printf 'Refusing unsafe HEALTH_TRACKER_RUNTIME_ROOT: %s\n' "$runtime_root" >&2; exit 2 ;;
    esac
}

check_status() {
    require_linux
    printf 'HealthTracker Linux service check\n'
    printf 'Data:    %s\n' "$data_root"
    printf 'Runtime: %s/current\n\n' "$runtime_root"

    if systemctl is-active --quiet "$receiver_unit"; then
        printf '\u2713 Receiver is active and enabled=%s\n' "$(systemctl is-enabled "$receiver_unit" 2>/dev/null || true)"
    else
        printf '\u2717 Receiver is not active\n'
        systemctl --no-pager --full status "$receiver_unit" 2>/dev/null | tail -n 12 || true
    fi
    local worker_unit
    for worker_unit in health-tracker-normalizer.service health-tracker-cloud-relay.service; do
        if systemctl is-active --quiet "$worker_unit"; then
            printf '\u2713 Worker is active: %s\n' "$worker_unit"
        else
            printf '\u2717 Worker is not active: %s\n' "$worker_unit"
        fi
    done
    if curl --fail --silent --show-error --max-time 5 \
        http://127.0.0.1:8787/api/v1/healthbeat/ready >/tmp/health-tracker-ready-check.json 2>/dev/null; then
        printf '\u2713 Deep readiness check passed\n'
        command -v jq >/dev/null 2>&1 && jq '{status,database,pending_normalization_jobs,pending_dashboard_snapshots,sequence_gaps}' /tmp/health-tracker-ready-check.json
    else
        printf '\u2717 Deep readiness check failed\n'
    fi
    rm -f /tmp/health-tracker-ready-check.json

    if command -v avahi-publish-service >/dev/null 2>&1 && systemctl is-active --quiet avahi-daemon.service; then
        printf '\u2713 Avahi automatic LAN discovery is available\n'
    else
        printf '! Avahi discovery is unavailable; manual LAN pairing still works\n'
    fi
    if [[ -r "$database_path" ]]; then
        printf 'SQLite: %s · quick_check=%s\n' \
            "$(du -h "$database_path" | awk '{print $1}')" \
            "$(sqlite3 "$database_path" 'PRAGMA quick_check;' | tail -n 1)"
    elif sudo -n -u "$service_user" test -r "$database_path" 2>/dev/null; then
        printf 'SQLite quick_check=%s\n' \
            "$(sudo -n -u "$service_user" sqlite3 "$database_path" 'PRAGMA quick_check;' | tail -n 1)"
    else
        printf '! Database is absent or not readable without sudo\n'
    fi
    systemctl list-timers --all --no-pager \
        'health-tracker-*.timer' 2>/dev/null | sed -n '1,12p' || true
}

write_unit_templates() {
    local output_dir="$1"
    local service_group="$2"
    local token_hash="$3"
    export HT_UNIT_OUTPUT="$output_dir" HT_RUNTIME="$runtime_root/current"
    export HT_DATA="$data_root" HT_DATABASE="$database_path" HT_EXPORTS="$export_dir"
    export HT_BACKUPS="$backup_dir" HT_KEY="$key_path" HT_USER="$service_user"
    export HT_GROUP="$service_group" HT_ENV_FILE="$environment_file" HT_TOKEN_HASH="$token_hash"
    export HT_PUBLIC_URLS="${HEALTH_RECEIVER_PUBLIC_URLS:-}"
    export HT_TRUSTED_LOGIN="${HEALTH_RECEIVER_TRUSTED_TAILSCALE_LOGIN:-}"
    "$(find_python)" <<'PY'
import os
from pathlib import Path

out = Path(os.environ["HT_UNIT_OUTPUT"])
runtime = os.environ["HT_RUNTIME"]
data = os.environ["HT_DATA"]
database = os.environ["HT_DATABASE"]
exports = os.environ["HT_EXPORTS"]
backups = os.environ["HT_BACKUPS"]
key = os.environ["HT_KEY"]
user = os.environ["HT_USER"]
group = os.environ["HT_GROUP"]
env_file = os.environ["HT_ENV_FILE"]

def quote(value: str) -> str:
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'

def write(name: str, body: str) -> None:
    (out / name).write_text(body.strip() + "\n", encoding="utf-8")

environment = {
    "HEALTH_TRACKER_HOME": data,
    "HEALTH_RECEIVER_DB": database,
    "HEALTH_RECEIVER_TOKEN_SHA256": os.environ["HT_TOKEN_HASH"],
    "HEALTH_RECEIVER_PUBLIC_URLS": os.environ["HT_PUBLIC_URLS"],
    "HEALTH_RECEIVER_TRUSTED_TAILSCALE_LOGIN": os.environ["HT_TRUSTED_LOGIN"],
    "HEALTH_RECEIVER_WORKERS_EXTERNAL": "1",
}
(out / "receiver.env").write_text(
    "".join(f"{name}={quote(value)}\n" for name, value in environment.items()),
    encoding="utf-8",
)

hardening = f"""
User={user}
Group={group}
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=read-only
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths={quote(data)}
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
""".strip()

write("health-tracker-receiver.service", f"""
[Unit]
Description=HealthTracker encrypted health receiver
Wants=network-online.target
After=network-online.target avahi-daemon.service

[Service]
Type=simple
EnvironmentFile=-{env_file}
Environment={quote('HOME=' + data)}
WorkingDirectory={quote(runtime)}
ExecStart={quote(runtime + '/.venv/bin/uvicorn')} receiver.app:app --host 0.0.0.0 --port 8787
Restart=always
RestartSec=5
TimeoutStopSec=30
{hardening}

[Install]
WantedBy=multi-user.target
""")

write("health-tracker-normalizer.service", f"""
[Unit]
Description=HealthTracker normalization and dashboard materialization worker
After=health-tracker-receiver.service

[Service]
Type=simple
EnvironmentFile=-{env_file}
Environment={quote('HOME=' + data)}
WorkingDirectory={quote(runtime)}
ExecStart={quote(runtime + '/.venv/bin/python')} -m receiver.worker normalization --data-root {quote(data)}
Restart=always
RestartSec=5
TimeoutStopSec=30
{hardening}

[Install]
WantedBy=multi-user.target
""")

write("health-tracker-cloud-relay.service", f"""
[Unit]
Description=HealthTracker encrypted cloud relay worker
Wants=network-online.target
After=network-online.target health-tracker-receiver.service

[Service]
Type=simple
EnvironmentFile=-{env_file}
Environment={quote('HOME=' + data)}
WorkingDirectory={quote(runtime)}
ExecStart={quote(runtime + '/.venv/bin/python')} -m receiver.worker cloud-relay --data-root {quote(data)}
Restart=always
RestartSec=5
TimeoutStopSec=30
{hardening}

[Install]
WantedBy=multi-user.target
""")

write("health-tracker-daily-export.service", f"""
[Unit]
Description=HealthTracker normalized daily export
After=health-tracker-receiver.service

[Service]
Type=oneshot
EnvironmentFile=-{env_file}
Environment={quote('HOME=' + data)}
WorkingDirectory={quote(runtime)}
ExecStart={quote(runtime + '/.venv/bin/python')} -m receiver.cli export --database {quote(database)} --timezone Asia/Shanghai --output-dir {quote(exports)}
{hardening}
""")
write("health-tracker-daily-export.timer", """
[Unit]
Description=Run HealthTracker daily export hourly

[Timer]
OnBootSec=3min
OnUnitActiveSec=1h
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
""")

write("health-tracker-watchdog.service", f"""
[Unit]
Description=HealthTracker deep readiness watchdog
After=health-tracker-receiver.service

[Service]
Type=oneshot
Environment="HEALTH_TRACKER_RECEIVER_UNIT=health-tracker-receiver.service"
Environment="HEALTH_TRACKER_NORMALIZER_UNIT=health-tracker-normalizer.service"
Environment="HEALTH_TRACKER_CLOUD_RELAY_UNIT=health-tracker-cloud-relay.service"
ExecStart=/bin/bash {quote(runtime + '/scripts/receiver_watchdog_linux.sh')}
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
""")
write("health-tracker-watchdog.timer", """
[Unit]
Description=Check HealthTracker readiness every five minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true
AccuracySec=30s

[Install]
WantedBy=timers.target
""")

write("health-tracker-maintenance.service", f"""
[Unit]
Description=HealthTracker integrity check and encrypted backup
After=health-tracker-receiver.service

[Service]
Type=oneshot
EnvironmentFile=-{env_file}
Environment={quote('HOME=' + data)}
Environment={quote('HEALTH_TRACKER_RUNTIME=' + runtime)}
Environment={quote('HEALTH_TRACKER_BACKUP_DIR=' + backups)}
Environment={quote('HEALTH_TRACKER_BACKUP_KEY=' + key)}
WorkingDirectory={quote(runtime)}
ExecStart=/bin/bash {quote(runtime + '/scripts/receiver_maintenance_linux.sh')}
{hardening}
""")
write("health-tracker-maintenance.timer", """
[Unit]
Description=Run HealthTracker encrypted backup daily

[Timer]
OnCalendar=*-*-* 03:15:00
Persistent=true
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
""")
PY
}

validate_rendered_units() {
    local rendered_dir="$1"
    local expected
    for expected in "${units[@]}"; do
        [[ -s "$rendered_dir/$expected" ]] || {
            printf 'Generated unit is missing: %s\n' "$expected" >&2
            return 1
        }
        grep -q '^\[Unit\]$' "$rendered_dir/$expected" || {
            printf 'Generated unit has no [Unit] section: %s\n' "$expected" >&2
            return 1
        }
    done
    grep -q '^ExecStart=' "$rendered_dir/$receiver_unit"
    grep -q '^HEALTH_TRACKER_HOME=' "$rendered_dir/receiver.env"
    if grep -R '\${' "$rendered_dir" >/dev/null; then
        printf 'Generated systemd configuration contains unresolved variables.\n' >&2
        return 1
    fi
}

configure_firewall() {
    (( open_firewall )) || return 0
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld.service; then
        sudo firewall-cmd --permanent --add-port=8787/tcp
        sudo firewall-cmd --reload
        printf '\u2713 Opened TCP 8787 with firewalld\n'
    elif command -v ufw >/dev/null 2>&1 && sudo ufw status | grep -q '^Status: active'; then
        sudo ufw allow 8787/tcp comment 'HealthTracker Receiver'
        printf '\u2713 Opened TCP 8787 with UFW\n'
    else
        printf '! No active firewalld/UFW detected; firewall was not changed\n'
    fi
}

install_release() {
    validate_targets
    local python_bin
    python_bin="$(find_python || true)"
    [[ -n "$python_bin" ]] || { printf 'Python 3.11 or newer is required.\n' >&2; exit 1; }
    if (( dry_run )); then
        local preview_dir
        preview_dir="$(mktemp -d "${TMPDIR:-/tmp}/health-tracker-systemd-preview.XXXXXX")"
        cleanup_dir="$preview_dir"
        local preview_hash
        preview_hash="$("$python_bin" -c 'print("0" * 64)')"
        write_unit_templates "$preview_dir" "$service_user" "$preview_hash"
        validate_rendered_units "$preview_dir"
        printf '[dry-run] Linux/systemd release -> %s/releases/<version>\n' "$runtime_root"
        printf '[dry-run] Persistent encrypted state -> %s\n' "$data_root"
        printf '[dry-run] Dedicated service account -> %s\n' "$service_user"
        printf '[dry-run] Receiver + isolated normalization/cloud workers + hourly export + 5-minute watchdog + daily encrypted backup\n'
        printf '[dry-run] Generated environment and all nine systemd units validated\n'
        (( open_firewall )) && printf '[dry-run] Open TCP 8787 using active firewalld/UFW\n'
        rm -rf -- "$preview_dir"
        cleanup_dir=""
        return 0
    fi
    require_linux
    for required in curl sqlite3 sudo; do
        command -v "$required" >/dev/null 2>&1 || { printf 'Missing required command: %s\n' "$required" >&2; exit 1; }
    done
    sudo -v

    if ! getent passwd "$service_user" >/dev/null; then
        local nologin_shell
        nologin_shell="$(command -v nologin || printf '/usr/sbin/nologin')"
        sudo useradd --system --user-group --no-create-home \
            --home-dir "$data_root" --shell "$nologin_shell" "$service_user"
    fi
    local service_group
    service_group="$(id -gn "$service_user")"

    sudo install -d -m 755 "$runtime_root" "$runtime_root/releases" "$environment_dir"
    sudo install -d -o "$service_user" -g "$service_group" -m 700 \
        "$data_root" "$data_root/keys" "$data_root/backups" "$backup_dir"
    sudo install -d -o "$service_user" -g "$service_group" -m 750 "$export_dir"
    sudo chown -R "$service_user:$service_group" "$data_root"

    local revision="source"
    if command -v git >/dev/null 2>&1; then
        revision="$(git -C "$project_dir" rev-parse --short HEAD 2>/dev/null || printf source)"
    fi
    local release_id release_dir
    release_id="$(date -u +%Y%m%dT%H%M%SZ)-$revision"
    release_dir="$runtime_root/releases/$release_id"
    [[ ! -e "$release_dir" ]] || { printf 'Release already exists: %s\n' "$release_dir" >&2; exit 1; }

    sudo install -d -m 755 "$release_dir" "$release_dir/scripts"
    sudo cp -a "$project_dir/receiver" "$release_dir/receiver"
    sudo cp -a "$project_dir/schemas" "$release_dir/schemas"
    sudo install -m 644 "$project_dir/VERSION" "$release_dir/VERSION"
    local release_commit="$revision"
    if command -v git >/dev/null 2>&1; then
        release_commit="$(git -C "$project_dir" rev-parse HEAD 2>/dev/null || printf '%s' "$revision")"
    fi
    printf '%s\n' "$release_commit" | sudo tee "$release_dir/RELEASE_COMMIT" >/dev/null
    sudo chmod 644 "$release_dir/RELEASE_COMMIT"
    sudo install -m 755 "$project_dir/scripts/secure_backup.py" "$release_dir/scripts/secure_backup.py"
    sudo install -m 755 "$project_dir/scripts/receiver_watchdog_linux.sh" "$release_dir/scripts/receiver_watchdog_linux.sh"
    sudo install -m 755 "$project_dir/scripts/receiver_maintenance_linux.sh" "$release_dir/scripts/receiver_maintenance_linux.sh"
    sudo "$python_bin" -m venv "$release_dir/.venv" || {
        printf 'Python venv creation failed; install your distribution python3-venv package.\n' >&2
        exit 1
    }
    sudo "$release_dir/.venv/bin/pip" install -q -r "$release_dir/receiver/requirements.txt"
    sudo "$release_dir/.venv/bin/pip" freeze | sudo tee "$release_dir/requirements.lock.txt" >/dev/null
    sudo chmod -R go-w "$release_dir"

    (
        cd "$release_dir"
        sudo -u "$service_user" env HOME="$data_root" HEALTH_TRACKER_HOME="$data_root" \
            HEALTH_RECEIVER_DB="$database_path" \
            "$release_dir/.venv/bin/python" -c \
            'from receiver.database import Database; import os; Database(os.environ["HEALTH_RECEIVER_DB"])'
    )

    local key_output
    key_output="$(sudo -u "$service_user" "$release_dir/.venv/bin/python" \
        "$release_dir/scripts/secure_backup.py" init-key --key "$key_path")"
    if grep -q '^created=yes$' <<<"$key_output"; then
        printf '\nIMPORTANT: save this backup recovery key in a password manager.\n'
        awk -F= '/^recovery_key_base64=/{print $2}' <<<"$key_output"
        printf '\n'
    fi

    local old_target=""
    if [[ -L "$runtime_root/current" ]]; then
        old_target="$(readlink "$runtime_root/current")"
    elif [[ -e "$runtime_root/current" ]]; then
        printf '%s/current is not a symlink; refusing to overwrite it.\n' "$runtime_root" >&2
        exit 1
    fi
    sudo ln -s "$release_dir" "$runtime_root/.current-$release_id"
    sudo mv -Tf "$runtime_root/.current-$release_id" "$runtime_root/current"

    local token_hash preserved_public_urls preserved_trusted_login
    token_hash="$("$python_bin" -c 'import hashlib,secrets; print(hashlib.sha256(secrets.token_bytes(32)).hexdigest())')"
    preserved_public_urls=""
    preserved_trusted_login=""
    if sudo test -f "$environment_file"; then
        local preserved
        preserved="$(sudo sed -n 's/^HEALTH_RECEIVER_TOKEN_SHA256="\(.*\)"$/\1/p' "$environment_file" | tail -n 1)"
        [[ -n "$preserved" ]] && token_hash="$preserved"
        preserved_public_urls="$(sudo sed -n 's/^HEALTH_RECEIVER_PUBLIC_URLS="\(.*\)"$/\1/p' "$environment_file" | tail -n 1)"
        preserved_trusted_login="$(sudo sed -n 's/^HEALTH_RECEIVER_TRUSTED_TAILSCALE_LOGIN="\(.*\)"$/\1/p' "$environment_file" | tail -n 1)"
    fi
    export HEALTH_RECEIVER_PUBLIC_URLS="${HEALTH_RECEIVER_PUBLIC_URLS:-$preserved_public_urls}"
    export HEALTH_RECEIVER_TRUSTED_TAILSCALE_LOGIN="${HEALTH_RECEIVER_TRUSTED_TAILSCALE_LOGIN:-$preserved_trusted_login}"

    local temporary_dir
    temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/health-tracker-systemd.XXXXXX")"
    cleanup_dir="$temporary_dir"
    write_unit_templates "$temporary_dir" "$service_group" "$token_hash"
    systemd-analyze verify "$temporary_dir"/*.service "$temporary_dir"/*.timer >/dev/null
    sudo install -o root -g "$service_group" -m 640 "$temporary_dir/receiver.env" "$environment_file"
    local unit
    for unit in "${units[@]}"; do
        sudo install -o root -g root -m 644 "$temporary_dir/$unit" "$unit_dir/$unit"
    done
    if command -v avahi-publish-service >/dev/null 2>&1; then
        sudo systemctl enable --now avahi-daemon.service || \
            printf '! Avahi is installed but could not be enabled; manual pairing remains available\n'
    else
        printf '! avahi-publish-service is absent; install avahi-utils for automatic iPhone discovery\n'
    fi
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$receiver_unit" \
        health-tracker-normalizer.service health-tracker-cloud-relay.service \
        health-tracker-daily-export.timer health-tracker-watchdog.timer health-tracker-maintenance.timer
    configure_firewall

    local ready=0 attempt
    for attempt in {1..30}; do
        if curl --fail --silent --max-time 3 \
            http://127.0.0.1:8787/api/v1/healthbeat/ready >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 1
    done
    if (( ! ready )); then
        printf 'New release failed readiness check.\n' >&2
        if [[ -n "$old_target" ]]; then
            sudo ln -s "$old_target" "$runtime_root/.rollback-$release_id"
            sudo mv -Tf "$runtime_root/.rollback-$release_id" "$runtime_root/current"
            sudo systemctl restart "$receiver_unit" \
                health-tracker-normalizer.service health-tracker-cloud-relay.service
            printf 'Runtime symlink rolled back to %s\n' "$old_target" >&2
        fi
        sudo systemctl --no-pager --full status "$receiver_unit" >&2 || true
        exit 1
    fi

    printf '\u2713 Receiver and isolated workers installed and ready\n'
    printf 'Dashboard: http://127.0.0.1:8787/dashboard\n'
    printf 'LAN API:   http://<linux-ip>:8787\n'
    printf 'Runtime:   %s\n' "$release_dir"
    printf 'Backups:   daily at 03:15, encrypted, retained for 14 days\n'
}

case "$command_name" in
    help|-h|--help) usage ;;
    check) check_status ;;
    install|update) install_release ;;
    backup-now)
        require_linux
        sudo systemctl start health-tracker-maintenance.service
        systemctl --no-pager --full status health-tracker-maintenance.service | tail -n 18 || true
        ;;
    *) printf 'Unknown command: %s\n' "$command_name" >&2; usage; exit 2 ;;
esac
