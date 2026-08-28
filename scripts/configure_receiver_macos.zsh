#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
command_name="${1:-check}"
[[ $# -gt 0 ]] && shift

mode="agent"
apply_power=0
dry_run=0
while (( $# )); do
    case "$1" in
        --mode)
            [[ $# -ge 2 ]] || { print -u2 -- "--mode 需要 agent 或 daemon"; exit 2; }
            mode="$2"
            shift 2
            ;;
        --apply-power)
            apply_power=1
            shift
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        -h|--help)
            command_name="help"
            shift
            ;;
        *)
            print -u2 -- "未知参数：$1"
            exit 2
            ;;
    esac
done

[[ "$mode" == "agent" || "$mode" == "daemon" ]] || { print -u2 -- "--mode 只能是 agent 或 daemon"; exit 2; }

support_dir="${HEALTH_TRACKER_HOME:-$HOME/Library/Application Support/HealthTracker}"
runtime_root="$support_dir/runtime"
database_path="$support_dir/health.sqlite3"
export_dir="$support_dir/exports"
backup_dir="$support_dir/backups/automatic"
key_path="$support_dir/keys/backup-encryption.key"
log_dir="${HEALTH_TRACKER_LOG_DIR:-$HOME/Library/Logs/HealthTracker}"
user_name="$(id -un)"
group_name="$(id -gn)"
uid="$(id -u)"
receiver_label="com.longfeihao.health-receiver"
normalizer_label="com.longfeihao.health-normalizer"
cloud_relay_label="com.longfeihao.health-cloud-relay"
export_label="com.longfeihao.health-daily-export"
watchdog_label="com.longfeihao.health-watchdog"
maintenance_label="com.longfeihao.health-maintenance"
labels=($receiver_label $normalizer_label $cloud_relay_label $export_label $watchdog_label $maintenance_label)

usage() {
    cat <<'EOF'
HealthTracker macOS 一键服务配置

用法：
  ./scripts/configure_receiver_macos.zsh check
  ./scripts/configure_receiver_macos.zsh install --mode agent [--apply-power] [--dry-run]
  ./scripts/configure_receiver_macos.zsh install --mode daemon [--apply-power] [--dry-run]
  ./scripts/configure_receiver_macos.zsh backup-now

模式：
  agent   当前用户登录后运行；无需 sudo，适合开发和个人电脑。
  daemon  开机即运行；需要 sudo，适合长期无人值守的 Mac mini。

--apply-power 会显式修改接电睡眠、网络唤醒和断电恢复设置，因此默认不启用。
EOF
}

find_python() {
    local candidate
    for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 "$(command -v python3 2>/dev/null || true)"; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        if "$candidate" -c 'import sys; raise SystemExit(sys.version_info < (3, 11))'; then
            print -r -- "$candidate"
            return 0
        fi
    done
    return 1
}

find_tailscale() {
    local candidate
    for candidate in "$(command -v tailscale 2>/dev/null || true)" /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        print -r -- "$candidate"
        return 0
    done
    return 1
}

existing_plist() {
    if [[ -f "$HOME/Library/LaunchAgents/$receiver_label.plist" ]]; then
        print -r -- "$HOME/Library/LaunchAgents/$receiver_label.plist"
    elif [[ -f "/Library/LaunchDaemons/$receiver_label.plist" ]]; then
        print -r -- "/Library/LaunchDaemons/$receiver_label.plist"
    fi
}

check_status() {
    print -- "HealthTracker 服务检查"
    print -- "数据目录：$support_dir"
    print -- "运行目录：$runtime_root/current"
    print -- ""
    if launchctl print "gui/$uid/$receiver_label" >/dev/null 2>&1; then
        print -- "✓ LaunchAgent 已加载"
        launchctl print "gui/$uid/$receiver_label" | awk '/state =|pid =|runs =|last exit code/{print "  "$0}'
    elif launchctl print "system/$receiver_label" >/dev/null 2>&1; then
        print -- "✓ LaunchDaemon 已加载"
        launchctl print "system/$receiver_label" | awk '/state =|pid =|runs =|last exit code/{print "  "$0}'
    else
        print -- "✗ Receiver 未由 launchd 加载"
    fi
    local worker_label
    for worker_label in $normalizer_label $cloud_relay_label; do
        if launchctl print "gui/$uid/$worker_label" >/dev/null 2>&1 || \
           launchctl print "system/$worker_label" >/dev/null 2>&1; then
            print -- "✓ Worker 已加载：$worker_label"
        else
            print -- "✗ Worker 未加载：$worker_label"
        fi
    done
    if curl --fail --silent --show-error --max-time 5 http://127.0.0.1:8787/api/v1/healthbeat/ready >/tmp/health-tracker-ready-check.json 2>/dev/null; then
        print -- "✓ 深度就绪检测通过"
        command -v jq >/dev/null 2>&1 && jq '{status,database,pending_normalization_jobs,pending_dashboard_snapshots,sequence_gaps}' /tmp/health-tracker-ready-check.json
    else
        print -- "✗ 深度就绪检测失败"
    fi
    rm -f /tmp/health-tracker-ready-check.json
    if [[ -f "$database_path" ]]; then
        print -- "SQLite：$(du -h "$database_path" | awk '{print $1}') · quick_check=$(sqlite3 "$database_path" 'PRAGMA quick_check;' | tail -1)"
    else
        print -- "✗ 数据库不存在"
    fi
    latest_backup=""
    if [[ -d "$backup_dir" ]]; then
        latest_backup="$(find "$backup_dir" -type f -name 'health-tracker-*.htbk' -print | sort | tail -1)"
    fi
    [[ -n "$latest_backup" ]] && print -- "最近自动备份：$latest_backup" || print -- "! 尚无自动加密备份"
    print -- ""
    print -- "接电电源配置："
    pmset -g custom | sed -n '/AC Power:/,$p' | grep -E 'AC Power:| sleep | displaysleep | disksleep | womp | powernap ' || true
}

generate_plists() {
    local output_dir="$1"
    local current="$runtime_root/current"
    local legacy_hash="$2"
    local public_urls="$3"
    local trusted_login="$4"
    local launch_domain="$5"
    export HT_PLIST_OUTPUT="$output_dir" HT_CURRENT="$current" HT_SUPPORT="$support_dir"
    export HT_DATABASE="$database_path" HT_EXPORTS="$export_dir" HT_BACKUPS="$backup_dir"
    export HT_LOGS="$log_dir" HT_HOME="$HOME" HT_USER="$user_name" HT_GROUP="$group_name"
    export HT_MODE="$mode" HT_TOKEN_HASH="$legacy_hash" HT_PUBLIC_URLS="$public_urls"
    export HT_TRUSTED_LOGIN="$trusted_login" HT_LAUNCH_DOMAIN="$launch_domain"
    "$(find_python)" <<'PY'
import os, plistlib
from pathlib import Path

out = Path(os.environ["HT_PLIST_OUTPUT"])
current = os.environ["HT_CURRENT"]
support = os.environ["HT_SUPPORT"]
logs = os.environ["HT_LOGS"]
mode = os.environ["HT_MODE"]
user = os.environ["HT_USER"]
group = os.environ["HT_GROUP"]
domain = os.environ["HT_LAUNCH_DOMAIN"]
common_env = {
    "HOME": os.environ["HT_HOME"],
    "HEALTH_TRACKER_HOME": support,
    "HEALTH_RECEIVER_DB": os.environ["HT_DATABASE"],
    "HEALTH_RECEIVER_TOKEN_SHA256": os.environ["HT_TOKEN_HASH"],
    "HEALTH_RECEIVER_PUBLIC_URLS": os.environ["HT_PUBLIC_URLS"],
    "HEALTH_RECEIVER_TRUSTED_TAILSCALE_LOGIN": os.environ["HT_TRUSTED_LOGIN"],
    "HEALTH_RECEIVER_WORKERS_EXTERNAL": "1",
}
service_env = {
    **common_env,
    "HEALTH_TRACKER_RUNTIME": current,
    "HEALTH_TRACKER_BACKUP_DIR": os.environ["HT_BACKUPS"],
    "HEALTH_TRACKER_BACKUP_KEY": f"{support}/keys/backup-encryption.key",
    "HEALTH_TRACKER_LOG_DIR": logs,
    "HEALTH_TRACKER_LAUNCH_DOMAIN": domain,
    "HEALTH_TRACKER_RECEIVER_LABEL": "com.longfeihao.health-receiver",
    "HEALTH_TRACKER_NORMALIZER_LABEL": "com.longfeihao.health-normalizer",
    "HEALTH_TRACKER_CLOUD_RELAY_LABEL": "com.longfeihao.health-cloud-relay",
    "HEALTH_TRACKER_OWNER": user,
    "HEALTH_TRACKER_OWNER_GROUP": group,
}

def write(name, value):
    path = out / f"{name}.plist"
    with path.open("wb") as handle:
        plistlib.dump(value, handle, fmt=plistlib.FMT_XML, sort_keys=False)

receiver = {
    "Label": "com.longfeihao.health-receiver",
    "ProgramArguments": [f"{current}/.venv/bin/uvicorn", "receiver.app:app", "--host", "0.0.0.0", "--port", "8787"],
    "WorkingDirectory": current,
    "EnvironmentVariables": common_env,
    "RunAtLoad": True,
    "KeepAlive": True,
    "ProcessType": "Background",
    "ThrottleInterval": 10,
    "StandardOutPath": f"{logs}/receiver.log",
    "StandardErrorPath": f"{logs}/receiver-error.log",
}
normalizer = {
    "Label": "com.longfeihao.health-normalizer",
    "ProgramArguments": [f"{current}/.venv/bin/python", "-m", "receiver.worker", "normalization", "--data-root", support],
    "WorkingDirectory": current,
    "EnvironmentVariables": common_env,
    "RunAtLoad": True,
    "KeepAlive": True,
    "ProcessType": "Background",
    "ThrottleInterval": 10,
    "StandardOutPath": f"{logs}/normalizer.log",
    "StandardErrorPath": f"{logs}/normalizer-error.log",
}
cloud_relay = {
    "Label": "com.longfeihao.health-cloud-relay",
    "ProgramArguments": [f"{current}/.venv/bin/python", "-m", "receiver.worker", "cloud-relay", "--data-root", support],
    "WorkingDirectory": current,
    "EnvironmentVariables": common_env,
    "RunAtLoad": True,
    "KeepAlive": True,
    "ProcessType": "Background",
    "ThrottleInterval": 10,
    "StandardOutPath": f"{logs}/cloud-relay.log",
    "StandardErrorPath": f"{logs}/cloud-relay-error.log",
}
daily = {
    "Label": "com.longfeihao.health-daily-export",
    "ProgramArguments": [f"{current}/.venv/bin/python", "-m", "receiver.cli", "export", "--database", os.environ["HT_DATABASE"], "--timezone", "Asia/Shanghai", "--output-dir", os.environ["HT_EXPORTS"]],
    "WorkingDirectory": current,
    "EnvironmentVariables": common_env,
    "RunAtLoad": True,
    "StartInterval": 3600,
    "ProcessType": "Background",
    "StandardOutPath": f"{logs}/daily-export.log",
    "StandardErrorPath": f"{logs}/daily-export-error.log",
}
watchdog = {
    "Label": "com.longfeihao.health-watchdog",
    "ProgramArguments": ["/bin/zsh", f"{current}/scripts/receiver_watchdog.zsh"],
    "WorkingDirectory": current,
    "EnvironmentVariables": service_env,
    "RunAtLoad": True,
    "StartInterval": 300,
    "ProcessType": "Background",
    "StandardOutPath": f"{logs}/watchdog.log",
    "StandardErrorPath": f"{logs}/watchdog-error.log",
}
maintenance = {
    "Label": "com.longfeihao.health-maintenance",
    "ProgramArguments": ["/bin/zsh", f"{current}/scripts/receiver_maintenance.zsh"],
    "WorkingDirectory": current,
    "EnvironmentVariables": service_env,
    "StartCalendarInterval": {"Hour": 3, "Minute": 15},
    "ProcessType": "Background",
    "StandardOutPath": f"{logs}/maintenance.log",
    "StandardErrorPath": f"{logs}/maintenance-error.log",
}
if mode == "daemon":
    for item in (receiver, normalizer, cloud_relay, daily):
        item["UserName"] = user
        item["GroupName"] = group
    # Watchdog and maintenance retain root authority so they can restart the
    # system-domain service and rotate its open log files.
write("com.longfeihao.health-receiver", receiver)
write("com.longfeihao.health-normalizer", normalizer)
write("com.longfeihao.health-cloud-relay", cloud_relay)
write("com.longfeihao.health-daily-export", daily)
write("com.longfeihao.health-watchdog", watchdog)
write("com.longfeihao.health-maintenance", maintenance)
PY
}

install_release() {
    local python_bin="$(find_python || true)"
    [[ -n "$python_bin" ]] || { print -u2 -- "需要 Python 3.11 或更高版本"; exit 1; }
    if (( dry_run )); then
        print -- "[dry-run] 将把当前源码复制到版本化目录：$runtime_root/releases/<version>"
        print -- "[dry-run] 将安装 $mode 模式的 Receiver、独立归一化/云拉取 Worker、每小时导出、5 分钟 watchdog 和每日维护任务"
        (( apply_power )) && print -- "[dry-run] 将通过 sudo 禁止接电自动睡眠并开启断电恢复"
        return
    fi

    mkdir -p "$support_dir" "$runtime_root/releases" "$export_dir" "$backup_dir" "$support_dir/keys" "$log_dir"
    chmod 700 "$support_dir/keys" "$backup_dir"
    local revision="source"
    command -v git >/dev/null 2>&1 && revision="$(git -C "$project_dir" rev-parse --short HEAD 2>/dev/null || print source)"
    local release_id="$(date -u +%Y%m%dT%H%M%SZ)-$revision"
    local release_dir="$runtime_root/releases/$release_id"
    [[ ! -e "$release_dir" ]] || { print -u2 -- "发布目录已存在：$release_dir"; exit 1; }
    mkdir -p "$release_dir/scripts"
    ditto "$project_dir/receiver" "$release_dir/receiver"
    ditto "$project_dir/schemas" "$release_dir/schemas"
    cp "$project_dir/scripts/secure_backup.py" "$release_dir/scripts/secure_backup.py"
    cp "$project_dir/scripts/receiver_watchdog.zsh" "$release_dir/scripts/receiver_watchdog.zsh"
    cp "$project_dir/scripts/receiver_maintenance.zsh" "$release_dir/scripts/receiver_maintenance.zsh"
    chmod 755 "$release_dir/scripts/"*.py "$release_dir/scripts/"*.zsh
    "$python_bin" -m venv "$release_dir/.venv"
    "$release_dir/.venv/bin/pip" install -q -r "$release_dir/receiver/requirements.txt"
    "$release_dir/.venv/bin/pip" freeze > "$release_dir/requirements.lock.txt"
    (
        cd "$release_dir"
        HEALTH_TRACKER_HOME="$support_dir" HEALTH_RECEIVER_DB="$database_path" \
            "$release_dir/.venv/bin/python" -c 'from receiver.database import Database; import os; Database(os.environ["HEALTH_RECEIVER_DB"])'
    )

    local key_output
    key_output="$("$release_dir/.venv/bin/python" "$release_dir/scripts/secure_backup.py" init-key --key "$key_path")"
    if print -r -- "$key_output" | grep -q '^created=yes$'; then
        print -- ""
        print -- "重要：已生成备份恢复密钥，请立即保存到密码管理器；丢失后无法恢复异机备份："
        print -r -- "$key_output" | awk -F= '/^recovery_key_base64=/{print $2}'
        print -- ""
    fi

    local old_target=""
    [[ -L "$runtime_root/current" ]] && old_target="$(readlink "$runtime_root/current")"
    [[ ! -e "$runtime_root/current" || -L "$runtime_root/current" ]] || { print -u2 -- "$runtime_root/current 不是符号链接，停止以避免覆盖"; exit 1; }
    ln -s "$release_dir" "$runtime_root/.current-$release_id"
    mv -h "$runtime_root/.current-$release_id" "$runtime_root/current"

    local old_plist="$(existing_plist || true)"
    local legacy_hash=""
    local public_urls=""
    local trusted_login=""
    if [[ -n "$old_plist" ]]; then
        legacy_hash="$(plutil -extract EnvironmentVariables.HEALTH_RECEIVER_TOKEN_SHA256 raw "$old_plist" 2>/dev/null || true)"
        public_urls="$(plutil -extract EnvironmentVariables.HEALTH_RECEIVER_PUBLIC_URLS raw "$old_plist" 2>/dev/null || true)"
        trusted_login="$(plutil -extract EnvironmentVariables.HEALTH_RECEIVER_TRUSTED_TAILSCALE_LOGIN raw "$old_plist" 2>/dev/null || true)"
    fi
    if [[ -z "$legacy_hash" ]]; then
        local legacy_token="$(openssl rand -hex 32)"
        legacy_hash="$(print -rn -- "$legacy_token" | shasum -a 256 | awk '{print $1}')"
    fi
    local tailscale_bin="$(find_tailscale || true)"
    if [[ -z "$public_urls" || -z "$trusted_login" ]] && [[ -n "$tailscale_bin" ]]; then
        local tailscale_json="$("$tailscale_bin" status --json 2>/dev/null || true)"
        if [[ -n "$tailscale_json" ]]; then
            [[ -z "$public_urls" ]] && public_urls="$(print -r -- "$tailscale_json" | "$release_dir/.venv/bin/python" -c 'import json,sys; v=json.load(sys.stdin).get("Self",{}).get("DNSName","").rstrip("."); print("https://"+v if v else "")')"
            [[ -z "$trusted_login" ]] && trusted_login="$(print -r -- "$tailscale_json" | "$release_dir/.venv/bin/python" -c 'import json,sys; d=json.load(sys.stdin); uid=str(d.get("Self",{}).get("UserID","")); print(d.get("User",{}).get(uid,{}).get("LoginName",""))')"
        fi
    fi

    # Keep this variable in script scope: an EXIT trap runs after this function's
    # local scope has ended, and `set -u` would otherwise treat it as unset.
    temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/health-tracker-plists.XXXXXX")"
    trap 'rm -rf -- "$temporary_dir"' EXIT
    local launch_domain="gui/$uid"
    [[ "$mode" == "daemon" ]] && launch_domain="system"
    generate_plists "$temporary_dir" "$legacy_hash" "$public_urls" "$trusted_login" "$launch_domain"
    plutil -lint "$temporary_dir/"*.plist >/dev/null

    local destination
    if [[ "$mode" == "agent" ]]; then
        if launchctl print "system/$receiver_label" >/dev/null 2>&1; then
            print -u2 -- "检测到系统级 Receiver；请改用 --mode daemon 更新，或先用 sudo 卸载旧 LaunchDaemon"
            exit 1
        fi
        destination="$HOME/Library/LaunchAgents"
        mkdir -p "$destination"
        local label
        for label in $labels; do
            launchctl bootout "gui/$uid/$label" 2>/dev/null || true
            cp "$temporary_dir/$label.plist" "$destination/$label.plist"
            chmod 644 "$destination/$label.plist"
            local bootstrap_ok=0
            local bootstrap_attempt=0
            for bootstrap_attempt in {1..5}; do
                if launchctl bootstrap "gui/$uid" "$destination/$label.plist" 2>/dev/null; then
                    bootstrap_ok=1
                    break
                fi
                sleep 1
            done
            (( bootstrap_ok )) || {
                print -u2 -- "无法加载 LaunchAgent：$label"
                exit 1
            }
        done
        launchctl kickstart -k "gui/$uid/$receiver_label"
        launchctl kickstart -k "gui/$uid/$normalizer_label"
        launchctl kickstart -k "gui/$uid/$cloud_relay_label"
    else
        destination="/Library/LaunchDaemons"
        sudo -v
        local label
        for label in $labels; do
            launchctl bootout "gui/$uid/$label" 2>/dev/null || true
            sudo launchctl bootout "system/$label" 2>/dev/null || true
            sudo cp "$temporary_dir/$label.plist" "$destination/$label.plist"
            sudo chown root:wheel "$destination/$label.plist"
            sudo chmod 644 "$destination/$label.plist"
            sudo launchctl bootstrap system "$destination/$label.plist"
        done
        sudo launchctl kickstart -k "system/$receiver_label"
        sudo launchctl kickstart -k "system/$normalizer_label"
        sudo launchctl kickstart -k "system/$cloud_relay_label"
    fi

    local ready=0
    local attempt
    for attempt in {1..20}; do
        if curl --fail --silent --max-time 3 http://127.0.0.1:8787/api/v1/healthbeat/ready >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 1
    done
    if (( ! ready )); then
        print -u2 -- "新版本未通过就绪检测"
        if [[ -n "$old_target" ]]; then
            ln -s "$old_target" "$runtime_root/.rollback-$release_id"
            mv -h "$runtime_root/.rollback-$release_id" "$runtime_root/current"
            if [[ "$mode" == "agent" ]]; then
                launchctl kickstart -k "gui/$uid/$receiver_label" || true
                launchctl kickstart -k "gui/$uid/$normalizer_label" || true
                launchctl kickstart -k "gui/$uid/$cloud_relay_label" || true
            else
                sudo launchctl kickstart -k "system/$receiver_label" || true
                sudo launchctl kickstart -k "system/$normalizer_label" || true
                sudo launchctl kickstart -k "system/$cloud_relay_label" || true
            fi
            print -u2 -- "已回滚运行目录到：$old_target"
        fi
        exit 1
    fi

    if (( apply_power )); then
        print -- "正在配置接电常驻、网络唤醒和断电恢复…"
        sudo pmset -c sleep 0 displaysleep 10 disksleep 0 womp 1 powernap 1
        sudo systemsetup -setrestartpowerfailure on
    fi

    print -- "✓ Receiver 与独立 Worker 已安装并通过深度就绪检测"
    print -- "模式：$mode"
    print -- "版本目录：$release_dir"
    print -- "面板：http://127.0.0.1:8787/dashboard"
    print -- "Agent：http://127.0.0.1:8787/api/v1/agent/catalog"
    print -- "自动加密备份：每天 03:15，保留 14 天"
}

case "$command_name" in
    help|-h|--help)
        usage
        ;;
    check)
        check_status
        ;;
    install|update)
        install_release
        ;;
    backup-now)
        current="$runtime_root/current"
        [[ -x "$current/.venv/bin/python" ]] || { print -u2 -- "尚未安装版本化 runtime"; exit 1; }
        HEALTH_TRACKER_HOME="$support_dir" \
        HEALTH_TRACKER_RUNTIME="$current" \
        HEALTH_RECEIVER_DB="$database_path" \
        HEALTH_TRACKER_BACKUP_DIR="$backup_dir" \
        HEALTH_TRACKER_BACKUP_KEY="$key_path" \
        HEALTH_TRACKER_LOG_DIR="$log_dir" \
            /bin/zsh "$current/scripts/receiver_maintenance.zsh"
        ;;
    *)
        print -u2 -- "未知命令：$command_name"
        usage
        exit 2
        ;;
esac
