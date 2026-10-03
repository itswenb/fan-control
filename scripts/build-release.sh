#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

fan_version="${FANCONTROL_VERSION:-}"
if [[ ! "$fan_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo '发布前请设置 FANCONTROL_VERSION=major.minor.patch。' >&2
    exit 1
fi
fan_key_file="${SPARKLE_PRIVATE_KEY_FILE:-.secrets/sparkle.key}"
fan_secret_stage=''
fan_archive_stage=''
trap 'if [[ -n "$fan_secret_stage" ]]; then /bin/rm -rf "$fan_secret_stage"; fi; if [[ -n "$fan_archive_stage" ]]; then /bin/rm -rf "$fan_archive_stage"; fi' EXIT
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    fan_secret_stage="$(mktemp -d)"
    fan_key_file="$fan_secret_stage/sparkle.key"
    (umask 077; printf '%s' "$SPARKLE_PRIVATE_KEY" > "$fan_key_file")
    unset SPARKLE_PRIVATE_KEY
fi
if [[ ! -f "$fan_key_file" ]]; then
    echo '缺少 Sparkle 私钥。请配置 SPARKLE_PRIVATE_KEY_FILE 或 Actions Secret SPARKLE_PRIVATE_KEY。' >&2
    exit 1
fi
fan_public_key="$(swift scripts/update-key.swift public "$fan_key_file")"
fan_expected_key="$(sed -n 's/^INFOPLIST_KEY_SUPublicEDKey = //p' Configuration/Updates.xcconfig)"
if [[ "$fan_public_key" != "$fan_expected_key" ]]; then
    echo '发布私钥与应用内公钥不匹配，拒绝生成更新。' >&2
    exit 1
fi

FANCONTROL_VERSION="$fan_version" bash scripts/build-dmg.sh
fan_release_directory="build/releases"
mkdir -p "$fan_release_directory"
fan_archive_stage="$(mktemp -d build/.fancontrol-release.XXXXXXXX)"
fan_archive="$fan_archive_stage/FanControl-$fan_version.dmg"
cp build/FanControl.dmg "$fan_archive"
fan_tools="build/SourcePackages/artifacts/sparkle/Sparkle/bin"
"$fan_tools/generate_appcast" --ed-key-file "$fan_key_file" \
    --download-url-prefix "https://github.com/itswenb/fan-control/releases/download/v$fan_version/" \
    --link 'https://github.com/itswenb/fan-control' --maximum-versions 1 "$fan_archive_stage"
"$fan_tools/sign_update" --ed-key-file "$fan_key_file" --verify "$fan_archive_stage/appcast.xml"
fan_signature="$("$fan_tools/sign_update" --ed-key-file "$fan_key_file" -p "$fan_archive")"
"$fan_tools/sign_update" --ed-key-file "$fan_key_file" --verify "$fan_archive" "$fan_signature"
python3 scripts/verify-release.py "$fan_version" "$fan_key_file" "$fan_archive" \
    "$fan_archive_stage/appcast.xml" "$fan_tools/sign_update" 'build/Build/Products/Release/Fan Control.app'
cp "$fan_archive" "$fan_release_directory/FanControl-$fan_version.dmg"
cp "$fan_archive_stage/appcast.xml" "$fan_release_directory/appcast.xml"
echo "签名发布产物已生成：$fan_release_directory/FanControl-$fan_version.dmg 和 $fan_release_directory/appcast.xml"
echo '仅生成产物，不上传 GitHub，也不启动控制服务。'
