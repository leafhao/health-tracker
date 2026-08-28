#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
xcode_project="$project_dir/ios/HealthBeat/Health Beat.xcodeproj"
derived_dir="$project_dir/build/ipa/DerivedData"
output_dir="$project_dir/build/ipa"
team_id="${DEVELOPMENT_TEAM:-}"
bundle_id="${BUNDLE_IDENTIFIER:-}"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [[ -z "$team_id" || -z "$bundle_id" ]]; then
    print -u2 -- "用法：DEVELOPMENT_TEAM='Team ID' BUNDLE_IDENTIFIER='唯一 Bundle ID' $0"
    exit 2
fi

rm -rf "$derived_dir"
mkdir -p "$output_dir"

xcodebuild \
    -project "$xcode_project" \
    -scheme "Health Beat" \
    -configuration Release \
    -sdk iphoneos \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$derived_dir" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$team_id" \
    PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
    CODE_SIGN_STYLE=Automatic \
    build

app_path="$derived_dir/Build/Products/Release-iphoneos/Health Beat.app"
[[ -d "$app_path" ]] || { print -u2 -- "未找到构建产物：$app_path"; exit 1; }

stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/health-tracker-ipa.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
mkdir -p "$stage_dir/Payload"
ditto "$app_path" "$stage_dir/Payload/Health Beat.app"
rm -f "$output_dir/HealthTracker.ipa"
(cd "$stage_dir" && ditto -c -k --sequesterRsrc Payload "$output_dir/HealthTracker.ipa")

print -- "IPA 已生成：$output_dir/HealthTracker.ipa"
print -- "安装后必须重新验证 HealthKit、后台刷新和实际增量同步。"
