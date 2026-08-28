#!/usr/bin/env bash
set -Eeuo pipefail

ready_url="${HEALTH_TRACKER_READY_URL:-http://127.0.0.1:8787/api/v1/healthbeat/ready}"
receiver_unit="${HEALTH_TRACKER_RECEIVER_UNIT:-health-tracker-receiver.service}"
normalizer_unit="${HEALTH_TRACKER_NORMALIZER_UNIT:-health-tracker-normalizer.service}"
cloud_relay_unit="${HEALTH_TRACKER_CLOUD_RELAY_UNIT:-health-tracker-cloud-relay.service}"
failure_file="${HEALTH_TRACKER_WATCHDOG_STATE:-/run/health-tracker-watchdog.failures}"
threshold="${HEALTH_TRACKER_WATCHDOG_FAILURES:-2}"

if [[ ! "$threshold" =~ ^[0-9]+$ ]] || (( threshold < 1 )); then
    printf 'Invalid watchdog failure threshold: %s\n' "$threshold" >&2
    exit 2
fi

if curl --fail --silent --show-error --max-time 10 "$ready_url" >/dev/null; then
    printf '0\n' >"$failure_file"
    exit 0
fi

failures=0
if [[ -f "$failure_file" ]]; then
    read -r failures <"$failure_file" || failures=0
fi
[[ "$failures" =~ ^[0-9]+$ ]] || failures=0
failures=$((failures + 1))
printf '%s\n' "$failures" >"$failure_file"
printf '[%s] Receiver readiness failed (%d consecutive failures)\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$failures" >&2

if (( failures >= threshold )); then
    systemctl restart "$receiver_unit" "$normalizer_unit" "$cloud_relay_unit"
    printf '[%s] systemd restart requested for Receiver and workers\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S%z')" >&2
    printf '0\n' >"$failure_file"
fi
