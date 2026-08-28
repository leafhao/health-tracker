#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
cd "$project_dir"
receiver_template="$project_dir/receiver/health-receiver.plist.example"
export_template="$project_dir/receiver/health-daily-export.plist.example"

support_dir="$HOME/Library/Application Support/HealthTracker"
database_path="$support_dir/health.sqlite3"
export_dir="$support_dir/exports"
launch_agents_dir="$HOME/Library/LaunchAgents"
receiver_plist="$launch_agents_dir/com.longfeihao.health-receiver.plist"
export_plist="$launch_agents_dir/com.longfeihao.health-daily-export.plist"
receiver_label="com.longfeihao.health-receiver"
export_label="com.longfeihao.health-daily-export"
launch_domain="gui/$(id -u)"

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

python_bin="$(find_python || true)"
if [[ -z "$python_bin" ]]; then
    print -u2 -- "需要 Python 3.11 或更高版本。可先执行：brew install python@3.12"
    exit 1
fi

print -- "项目目录：$project_dir"
print -- "Python：$python_bin"
# v1 HTTP ingestion remains available during migration, but its randomly generated
# credential is no longer an administrator password or an iPhone pairing secret.
legacy_token_hash=""
if [[ -f "$receiver_plist" ]]; then
    legacy_token_hash="$(plutil -extract EnvironmentVariables.HEALTH_RECEIVER_TOKEN_SHA256 raw "$receiver_plist" 2>/dev/null || true)"
fi
if [[ -z "$legacy_token_hash" ]]; then
    legacy_token="$(openssl rand -hex 32)"
    legacy_token_hash="$(print -rn -- "$legacy_token" | shasum -a 256 | awk '{print $1}')"
fi

mkdir -p "$support_dir" "$export_dir" "$launch_agents_dir" "$HOME/Library/Logs/HealthTracker"

if [[ ! -x "$project_dir/.venv/bin/python" ]]; then
    "$python_bin" -m venv "$project_dir/.venv"
fi
"$project_dir/.venv/bin/pip" install -q -r "$project_dir/receiver/requirements.txt"

tailscale_ip=""
tailscale_dns=""
tailscale_login=""
if command -v tailscale >/dev/null 2>&1; then
    tailscale_ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    tailscale_dns="$(tailscale status --json 2>/dev/null | "$project_dir/.venv/bin/python" -c 'import json,sys; print(json.load(sys.stdin).get("Self",{}).get("DNSName", "").rstrip("."))' 2>/dev/null || true)"
    tailscale_login="$(tailscale status --json 2>/dev/null | "$project_dir/.venv/bin/python" -c 'import json,sys; d=json.load(sys.stdin); uid=str(d.get("Self",{}).get("UserID", "")); print(d.get("User",{}).get(uid,{}).get("LoginName", ""))' 2>/dev/null || true)"
fi
public_urls=""
[[ -n "$tailscale_dns" ]] && public_urls="https://$tailscale_dns"

# Importing Database initializes the schema without starting a network listener.
HEALTH_RECEIVER_DB="$database_path" "$project_dir/.venv/bin/python" -c \
    'from receiver.database import Database; import os; Database(os.environ["HEALTH_RECEIVER_DB"])'

timestamp="$(date +%Y%m%d-%H%M%S)"
for plist in "$receiver_plist" "$export_plist"; do
    if [[ -f "$plist" ]]; then
        cp "$plist" "$plist.backup-$timestamp"
    fi
done

cp "$receiver_template" "$receiver_plist"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $project_dir/.venv/bin/uvicorn" "$receiver_plist"
plutil -replace WorkingDirectory -string "$project_dir" "$receiver_plist"
plutil -replace EnvironmentVariables.HEALTH_RECEIVER_DB -string "$database_path" "$receiver_plist"
plutil -replace EnvironmentVariables.HEALTH_RECEIVER_TOKEN_SHA256 -string "$legacy_token_hash" "$receiver_plist"
if plutil -extract EnvironmentVariables.HEALTH_RECEIVER_PUBLIC_URLS raw "$receiver_plist" >/dev/null 2>&1; then
    plutil -replace EnvironmentVariables.HEALTH_RECEIVER_PUBLIC_URLS -string "$public_urls" "$receiver_plist"
else
    plutil -insert EnvironmentVariables.HEALTH_RECEIVER_PUBLIC_URLS -string "$public_urls" "$receiver_plist"
fi
if plutil -extract EnvironmentVariables.HEALTH_RECEIVER_TRUSTED_TAILSCALE_LOGIN raw "$receiver_plist" >/dev/null 2>&1; then
    plutil -replace EnvironmentVariables.HEALTH_RECEIVER_TRUSTED_TAILSCALE_LOGIN -string "$tailscale_login" "$receiver_plist"
else
    plutil -insert EnvironmentVariables.HEALTH_RECEIVER_TRUSTED_TAILSCALE_LOGIN -string "$tailscale_login" "$receiver_plist"
fi
plutil -replace StandardOutPath -string "$HOME/Library/Logs/HealthTracker/receiver.log" "$receiver_plist"
plutil -replace StandardErrorPath -string "$HOME/Library/Logs/HealthTracker/receiver-error.log" "$receiver_plist"

cp "$export_template" "$export_plist"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $project_dir/.venv/bin/python" "$export_plist"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:5 $database_path" "$export_plist"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:9 $export_dir" "$export_plist"
plutil -replace WorkingDirectory -string "$project_dir" "$export_plist"
plutil -replace StandardOutPath -string "$HOME/Library/Logs/HealthTracker/daily-export.log" "$export_plist"
plutil -replace StandardErrorPath -string "$HOME/Library/Logs/HealthTracker/daily-export-error.log" "$export_plist"

plutil -lint "$receiver_plist" "$export_plist"
launchctl bootout "$launch_domain/$receiver_label" 2>/dev/null || true
launchctl bootout "$launch_domain/$export_label" 2>/dev/null || true
sleep 1
if ! launchctl bootstrap "$launch_domain" "$receiver_plist"; then
    sleep 1
    launchctl bootstrap "$launch_domain" "$receiver_plist"
fi
if ! launchctl bootstrap "$launch_domain" "$export_plist"; then
    sleep 1
    launchctl bootstrap "$launch_domain" "$export_plist"
fi
launchctl kickstart -k "$launch_domain/$receiver_label"
launchctl kickstart -k "$launch_domain/$export_label"

sleep 2
curl --fail --silent --show-error http://127.0.0.1:8787/api/v1/healthbeat/health >/dev/null

print -- ""
print -- "Receiver 已启动，无需设置独立密码。管理页："
print -- "本机地址：http://127.0.0.1:8787/dashboard"
[[ -n "$tailscale_dns" ]] && print -- "Tailscale 地址：https://$tailscale_dns/dashboard"
print -- "Receiver 已在局域网通过 Bonjour 广播；手机会自动发现，管理页负责一键确认。"
print -- "管理页仍只信任本机；8787 仅向局域网提供公开身份和安全配对接口。"
print -- ""
print -- "数据库：$database_path"
print -- "每日 JSON：$export_dir"
print -- "日志：$HOME/Library/Logs/HealthTracker"
open http://127.0.0.1:8787/dashboard >/dev/null 2>&1 || true
