#!/bin/zsh
set -u
setopt pipefail

# Rebuild and reinstall the Health Tracker iOS app before a free Personal Team
# provisioning profile expires. This script is intended to run as a user
# LaunchAgent on the always-on Mac that is paired with the iPhone.

config_path="${HEALTH_TRACKER_IOS_RENEW_CONFIG:-$HOME/.config/health-tracker/ios-renewal.conf}"
if [[ ! -r "$config_path" ]]; then
    print -u2 -- "未找到配置：$config_path"
    exit 2
fi

source "$config_path"

: "${REPO_PATH:?配置缺少 REPO_PATH}"
: "${XCODE_PATH:?配置缺少 XCODE_PATH}"
: "${TEAM_ID:?配置缺少 TEAM_ID}"
: "${BUNDLE_ID:?配置缺少 BUNDLE_ID}"
: "${DEVICE_ID:?配置缺少 DEVICE_ID}"

threshold_seconds="${RENEW_THRESHOLD_SECONDS:-259200}"
notify_after_failures="${NOTIFY_AFTER_FAILURES:-3}"
state_dir="${STATE_DIR:-$HOME/Library/Application Support/HealthTrackerSigner}"
project_path="$REPO_PATH/ios/HealthBeat/Health Beat.xcodeproj"
scheme_name="Health Beat"
derived_dir="$state_dir/DerivedData"
app_path="$derived_dir/Build/Products/Release-iphoneos/Health Beat.app"
status_path="$state_dir/status.json"
state_path="$state_dir/renewal-state.plist"
lock_path="$state_dir/renewal.lock"
log_path="$state_dir/renewal.log"

mkdir -p "$state_dir"
touch "$log_path"
exec >>"$log_path" 2>&1

timestamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { print -- "[$(timestamp)] $*"; }

if ! mkdir "$lock_path" 2>/dev/null; then
    log "已有续签检查正在运行，本次跳过"
    exit 0
fi
trap 'rmdir "$lock_path" 2>/dev/null || true' EXIT INT TERM

developer_dir="$XCODE_PATH/Contents/Developer"
if [[ ! -x "$developer_dir/usr/bin/xcodebuild" ]]; then
    log "错误：Xcode 不完整：$XCODE_PATH"
    exit 3
fi
export DEVELOPER_DIR="$developer_dir"

if [[ -n "${SIGNING_KEYCHAIN_PATH:-}" ]]; then
    signing_keychain_password_file="${SIGNING_KEYCHAIN_PASSWORD_FILE:-}"
    if [[ ! -f "$SIGNING_KEYCHAIN_PATH" || ! -r "$signing_keychain_password_file" ]]; then
        log "错误：独立签名钥匙串或密码文件不存在"
        exit 4
    fi
    signing_keychain_password="$(<"$signing_keychain_password_file")"
    if ! security unlock-keychain -p "$signing_keychain_password" "$SIGNING_KEYCHAIN_PATH"; then
        log "错误：无法解锁独立签名钥匙串"
        exit 4
    fi
    security list-keychains -d user -s \
        "$SIGNING_KEYCHAIN_PATH" \
        "$HOME/Library/Keychains/login.keychain-db" \
        /Library/Keychains/System.keychain
fi

typeset -a signing_build_settings
signing_build_settings=()
if [[ -n "${SIGNING_KEYCHAIN_PATH:-}" ]]; then
    signing_build_settings+=("OTHER_CODE_SIGN_FLAGS=--keychain $SIGNING_KEYCHAIN_PATH")
fi

read_state() {
    local key="$1" default_value="${2:-}"
    if [[ -f "$state_path" ]]; then
        /usr/libexec/PlistBuddy -c "Print :$key" "$state_path" 2>/dev/null || print -r -- "$default_value"
    else
        print -r -- "$default_value"
    fi
}

write_plist_value() {
    local key="$1" type="$2" value="$3"
    [[ -f "$state_path" ]] || /usr/libexec/PlistBuddy -c 'Save' "$state_path" >/dev/null
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$state_path" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$state_path" >/dev/null
}

write_status() {
    local state="$1" message="$2" expiry_epoch="${3:-0}" failures="${4:-0}"
    STATUS_STATE="$state" STATUS_MESSAGE="$message" STATUS_EXPIRY="$expiry_epoch" \
        STATUS_FAILURES="$failures" STATUS_UPDATED="$(timestamp)" STATUS_PATH="$status_path" \
        /usr/bin/python3 <<'PY'
import datetime
import json
import os

expiry = int(os.environ.get("STATUS_EXPIRY", "0") or 0)
payload = {
    "state": os.environ["STATUS_STATE"],
    "message": os.environ["STATUS_MESSAGE"],
    "updated_at": os.environ["STATUS_UPDATED"],
    "consecutive_failures": int(os.environ.get("STATUS_FAILURES", "0") or 0),
    "profile_expiration": (
        datetime.datetime.fromtimestamp(expiry, datetime.timezone.utc).isoformat()
        if expiry else None
    ),
    "remaining_seconds": max(0, expiry - int(datetime.datetime.now().timestamp())) if expiry else None,
}
tmp = os.environ["STATUS_PATH"] + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
os.replace(tmp, os.environ["STATUS_PATH"])
PY
}

profile_expiry_epoch() {
    local profile="$1" decoded
    decoded="$(mktemp "$state_dir/profile.XXXXXX.plist")"
    if ! security cms -D -i "$profile" >"$decoded" 2>/dev/null; then
        rm -f "$decoded"
        return 1
    fi
    /usr/bin/python3 - "$decoded" <<'PY'
import datetime
import plistlib
import sys

with open(sys.argv[1], "rb") as fh:
    value = plistlib.load(fh)["ExpirationDate"]
if value.tzinfo is None:
    value = value.replace(tzinfo=datetime.timezone.utc)
print(int(value.timestamp()))
PY
    local result=$?
    rm -f "$decoded"
    return $result
}

notify_failure() {
    local message="$1"
    /usr/bin/osascript -e \
        "display notification \"${message//\"/\\\"}\" with title \"健康同步续签失败\"" \
        >/dev/null 2>&1 || true
}

record_failure() {
    local message="$1" expiry_epoch="${2:-0}"
    local failures="$(read_state consecutive_failures 0)"
    (( failures += 1 ))
    write_plist_value consecutive_failures integer "$failures"
    write_plist_value last_error string "${message//$'\n'/ }"
    write_status "error" "$message" "$expiry_epoch" "$failures"
    log "失败（连续 $failures 次）：$message"
    if (( failures >= notify_after_failures )); then
        notify_failure "$message"
    fi
}

current_commit="$(git -C "$REPO_PATH" rev-parse HEAD:ios/HealthBeat 2>/dev/null || \
    git -C "$REPO_PATH" rev-parse HEAD 2>/dev/null || print unknown)"
last_commit="$(read_state installed_commit '')"
last_expiry="$(read_state profile_expiry_epoch 0)"
now_epoch="$(date +%s)"
remaining=$(( last_expiry - now_epoch ))

if (( remaining > threshold_seconds )) && [[ "$current_commit" == "$last_commit" ]]; then
    write_status "healthy" "签名仍在安全期内，无需续签" "$last_expiry" 0
    exit 0
fi

if (( last_expiry > 0 )); then
    log "需要续签：现有记录剩余 $(( remaining / 3600 )) 小时，提交 $current_commit"
else
    log "需要首次建立续签状态，提交 $current_commit"
fi
write_status "working" "正在准备签名和覆盖安装" "$last_expiry" "$(read_state consecutive_failures 0)"

pending_expiry=0
if [[ -f "$app_path/embedded.mobileprovision" ]]; then
    pending_expiry="$(profile_expiry_epoch "$app_path/embedded.mobileprovision" 2>/dev/null || print 0)"
fi
pending_commit="$(read_state pending_commit '')"

if (( pending_expiry <= now_epoch + 86400 )) || [[ "$pending_commit" != "$current_commit" ]]; then
    log "使用 Xcode 自动签名构建新版本"
    rm -rf "$derived_dir"
    mkdir -p "$derived_dir"
    build_log="$state_dir/xcodebuild.log"
    if ! xcodebuild \
        -project "$project_path" \
        -scheme "$scheme_name" \
        -configuration Release \
        -sdk iphoneos \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$derived_dir" \
        -allowProvisioningUpdates \
        -allowProvisioningDeviceRegistration \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
        CODE_SIGN_STYLE=Automatic \
        "${signing_build_settings[@]}" \
        build >"$build_log" 2>&1; then
        detail="$(tail -n 8 "$build_log" | tr '\n' ' ' | cut -c1-600)"
        record_failure "Xcode 构建或自动签名失败：$detail" "$last_expiry"
        exit 10
    fi

    if [[ ! -d "$app_path" || ! -f "$app_path/embedded.mobileprovision" ]]; then
        record_failure "Xcode 构建成功但没有找到已签名 App" "$last_expiry"
        exit 11
    fi

    entitlements_file="$state_dir/entitlements.plist"
    if ! codesign -d --entitlements :- "$app_path" >"$entitlements_file" 2>/dev/null || \
       [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.healthkit' "$entitlements_file" 2>/dev/null)" != "true" ]] || \
       [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.healthkit.background-delivery' "$entitlements_file" 2>/dev/null)" != "true" ]]; then
        record_failure "签名产物缺少 HealthKit 或后台交付 entitlement，拒绝安装" "$last_expiry"
        exit 12
    fi

    pending_expiry="$(profile_expiry_epoch "$app_path/embedded.mobileprovision" 2>/dev/null || print 0)"
    if (( pending_expiry <= now_epoch + 86400 )); then
        record_failure "新签名描述文件有效期异常，拒绝安装" "$last_expiry"
        exit 13
    fi
    write_plist_value pending_commit string "$current_commit"
    write_plist_value pending_expiry_epoch integer "$pending_expiry"
    log "构建完成，新描述文件到期时间戳：$pending_expiry"
else
    log "复用上次构建但尚未安装成功的签名产物"
fi

install_json="$state_dir/devicectl-install.json"
install_log="$state_dir/devicectl-install.log"
rm -f "$install_json" "$install_log"
if ! xcrun devicectl device install app \
    --device "$DEVICE_ID" \
    --timeout 120 \
    --json-output "$install_json" \
    --log-output "$install_log" \
    "$app_path" >/dev/null 2>&1; then
    detail="$(tail -n 10 "$install_log" 2>/dev/null | tr '\n' ' ' | cut -c1-600)"
    [[ -n "$detail" ]] || detail="iPhone 当前不可达、未解锁或配对失效"
    record_failure "覆盖安装失败，将保留产物后重试：$detail" "$last_expiry"
    exit 20
fi

write_plist_value installed_commit string "$current_commit"
write_plist_value profile_expiry_epoch integer "$pending_expiry"
write_plist_value last_success_epoch integer "$(date +%s)"
write_plist_value consecutive_failures integer 0
write_plist_value pending_commit string ''
write_plist_value pending_expiry_epoch integer 0
write_status "healthy" "已完成自动重签和覆盖安装" "$pending_expiry" 0
log "续签成功：已覆盖安装 $BUNDLE_ID，App 数据容器未删除"
