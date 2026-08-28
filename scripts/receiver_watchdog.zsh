#!/bin/zsh
set -euo pipefail

ready_url="${HEALTH_TRACKER_READY_URL:-http://127.0.0.1:8787/api/v1/healthbeat/ready}"
launch_domain="${HEALTH_TRACKER_LAUNCH_DOMAIN:-gui/$(id -u)}"
receiver_label="${HEALTH_TRACKER_RECEIVER_LABEL:-com.longfeihao.health-receiver}"
failure_file="${HEALTH_TRACKER_WATCHDOG_STATE:-${TMPDIR:-/tmp}/health-tracker-watchdog.failures}"
threshold="${HEALTH_TRACKER_WATCHDOG_FAILURES:-2}"

if curl --fail --silent --show-error --max-time 10 "$ready_url" >/dev/null; then
    print -r -- 0 >| "$failure_file"
    exit 0
fi

failures=0
[[ -f "$failure_file" ]] && failures="$(<"$failure_file")"
[[ "$failures" == <-> ]] || failures=0
failures=$((failures + 1))
print -r -- "$failures" >| "$failure_file"
print -u2 -- "[$(date '+%Y-%m-%dT%H:%M:%S%z')] Receiver readiness 失败（连续 $failures 次）"

if (( failures >= threshold )); then
    launchctl kickstart -k "$launch_domain/$receiver_label"
    print -u2 -- "[$(date '+%Y-%m-%dT%H:%M:%S%z')] 已请求 launchd 重启 Receiver"
    print -r -- 0 >| "$failure_file"
fi
