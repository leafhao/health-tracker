#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_path="${HEALTH_TRACKER_REPO_PATH:-${script_dir:h}}"
team_id="${DEVELOPMENT_TEAM:-N3886D2P7L}"
bundle_id="${BUNDLE_IDENTIFIER:-com.longfeihao.healthsync}"
device_id="${IOS_DEVICE_ID:-}"
label="com.longfeihao.health-tracker-ios-renewal"
config_dir="$HOME/.config/health-tracker"
config_path="$config_dir/ios-renewal.conf"
state_dir="$HOME/Library/Application Support/HealthTrackerSigner"
plist_path="$HOME/Library/LaunchAgents/$label.plist"
default_signing_keychain_path="$HOME/Library/Keychains/HealthTrackerSigner.keychain-db"
default_signing_keychain_password_file="$state_dir/keychain-password"
if [[ -n "${SIGNING_KEYCHAIN_PATH:-}" ]]; then
    signing_keychain_path="$SIGNING_KEYCHAIN_PATH"
    signing_keychain_password_file="${SIGNING_KEYCHAIN_PASSWORD_FILE:-$default_signing_keychain_password_file}"
elif [[ -f "$default_signing_keychain_path" && -r "$default_signing_keychain_password_file" ]]; then
    signing_keychain_path="$default_signing_keychain_path"
    signing_keychain_password_file="$default_signing_keychain_password_file"
else
    signing_keychain_path=""
    signing_keychain_password_file=""
fi

find_xcode() {
    local candidate
    for candidate in \
        "${XCODE_PATH:-}" \
        "$HOME/Applications/Xcode.app" \
        /Applications/Xcode.app; do
        if [[ -n "$candidate" && -x "$candidate/Contents/Developer/usr/bin/xcodebuild" ]]; then
            print -r -- "$candidate"
            return 0
        fi
    done
    return 1
}

usage() {
    cat <<'EOF'
用法：
  IOS_DEVICE_ID='iPhone UDID' ./scripts/configure_ios_autorenew_macos.zsh install
  ./scripts/configure_ios_autorenew_macos.zsh run-now
  ./scripts/configure_ios_autorenew_macos.zsh preflight
  ./scripts/configure_ios_autorenew_macos.zsh status
  ./scripts/configure_ios_autorenew_macos.zsh uninstall

可选环境变量：DEVELOPMENT_TEAM、BUNDLE_IDENTIFIER、XCODE_PATH、
HEALTH_TRACKER_REPO_PATH。配置不包含 Apple ID 密码或其他密钥。
EOF
}

command="${1:-status}"
uid="$(id -u)"

case "$command" in
    preflight)
        xcode_path="$(find_xcode)" || {
            print -u2 -- "✗ 未找到完整 Xcode.app"
            exit 2
        }
        export DEVELOPER_DIR="$xcode_path/Contents/Developer"
        if [[ -f "$signing_keychain_path" && -r "$signing_keychain_password_file" ]]; then
            security unlock-keychain -p "$(<"$signing_keychain_password_file")" "$signing_keychain_path"
            security list-keychains -d user -s \
                "$signing_keychain_path" \
                "$HOME/Library/Keychains/login.keychain-db" \
                /Library/Keychains/System.keychain
            print -- "✓ 独立签名钥匙串已解锁"
        fi
        print -- "Xcode: $xcode_path"
        xcodebuild -version
        if xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
            print -- "✓ Xcode 许可与首次初始化已完成"
        else
            print -- "✗ Xcode 许可或首次初始化尚未完成"
        fi
        identity_count="$(security find-identity -v -p codesigning | awk '/valid identities found/{print $1}')"
        if (( ${identity_count:-0} > 0 )); then
            print -- "✓ 找到可用代码签名身份"
            security find-identity -v -p codesigning | sed -n '1,5p'
        else
            print -- "✗ 没有可用代码签名身份；请在 Xcode → Settings → Accounts 登录 Apple ID"
        fi
        if [[ -n "$device_id" ]]; then
            device_json="$(mktemp "${TMPDIR:-/tmp}/health-tracker-devices.XXXXXX")"
            if xcrun devicectl list devices --timeout 15 --json-output "$device_json" >/dev/null 2>&1 && \
               grep -q "$device_id" "$device_json"; then
                print -- "✓ Xcode 能识别目标 iPhone：$device_id"
            else
                print -- "✗ 当前未识别目标 iPhone：$device_id"
            fi
            unlink "$device_json"
        else
            print -- "提示：设置 IOS_DEVICE_ID 后可同时检查真机连接"
        fi
        ;;
    install)
        xcode_path="$(find_xcode)" || {
            print -u2 -- "未找到完整 Xcode.app，请先安装 Xcode。"
            exit 2
        }
        [[ -n "$device_id" ]] || {
            print -u2 -- "安装时必须通过 IOS_DEVICE_ID 指定已配对 iPhone 的 UDID。"
            exit 2
        }
        [[ -d "$repo_path/.git" && -f "$repo_path/ios/HealthBeat/Health Beat.xcodeproj/project.pbxproj" ]] || {
            print -u2 -- "项目路径无效：$repo_path"
            exit 2
        }
        mkdir -p "$config_dir" "$state_dir" "$HOME/Library/LaunchAgents"
        umask 077
        cat >"$config_path" <<EOF
REPO_PATH=${(qqq)repo_path}
XCODE_PATH=${(qqq)xcode_path}
TEAM_ID=${(qqq)team_id}
BUNDLE_ID=${(qqq)bundle_id}
DEVICE_ID=${(qqq)device_id}
RENEW_THRESHOLD_SECONDS=259200
NOTIFY_AFTER_FAILURES=3
STATE_DIR=${(qqq)state_dir}
SIGNING_KEYCHAIN_PATH=${(qqq)signing_keychain_path}
SIGNING_KEYCHAIN_PASSWORD_FILE=${(qqq)signing_keychain_password_file}
EOF
        chmod 600 "$config_path"
        chmod +x "$repo_path/scripts/renew_ios_personal_team.zsh"
        cat >"$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>$repo_path/scripts/renew_ios_personal_team.zsh</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$repo_path</string>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>1800</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>$state_dir/launchd.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>$state_dir/launchd.stderr.log</string>
</dict>
</plist>
EOF
        plutil -lint "$plist_path" >/dev/null
        launchctl bootout "gui/$uid/$label" 2>/dev/null || true
        launchctl bootstrap "gui/$uid" "$plist_path"
        launchctl enable "gui/$uid/$label"
        launchctl kickstart -k "gui/$uid/$label"
        print -- "已安装自动续签任务：$label"
        print -- "首次运行会验证 Xcode 账号、签名和真机连接。"
        ;;
    run-now)
        [[ -f "$plist_path" ]] || { print -u2 -- "尚未安装自动续签任务"; exit 2; }
        launchctl kickstart -k "gui/$uid/$label"
        print -- "已触发续签检查"
        ;;
    status)
        if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
            print -- "launchd: 已加载"
            launchctl print "gui/$uid/$label" | awk '/state =|runs =|last exit code =/{print "  "$0}'
        else
            print -- "launchd: 未加载"
        fi
        if [[ -f "$state_dir/status.json" ]]; then
            print -- "状态："
            cat "$state_dir/status.json"
        else
            print -- "状态：尚无运行结果"
        fi
        print -- "日志：$state_dir/renewal.log"
        ;;
    uninstall)
        launchctl bootout "gui/$uid/$label" 2>/dev/null || true
        rm -f "$plist_path"
        print -- "已移除 launchd 任务；签名状态与日志仍保留在：$state_dir"
        ;;
    *)
        usage
        exit 2
        ;;
esac
