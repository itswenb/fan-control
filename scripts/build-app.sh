#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

fan_build_configuration="${FANCONTROL_CONFIGURATION:-Release}"
fan_sign_identity="${FANCONTROL_SIGN_IDENTITY:--}"
fan_sign_arguments=(--timestamp=none)
if [[ "$fan_sign_identity" != '-' ]]; then
    fan_sign_arguments=(--options runtime --timestamp)
fi
if [[ -n "${1:-}" ]]; then
    echo '用法：bash scripts/build-app.sh' >&2
    exit 1
fi
fan_version_arguments=()
if [[ -n "${FANCONTROL_VERSION:-}" ]]; then
    if [[ ! "$FANCONTROL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo 'FANCONTROL_VERSION 必须使用 major.minor.patch 格式。' >&2
        exit 1
    fi
    fan_version_arguments=("MARKETING_VERSION=$FANCONTROL_VERSION" "CURRENT_PROJECT_VERSION=$FANCONTROL_VERSION")
fi

xcodebuild -quiet -project macs-fan-control.xcodeproj -scheme macs-fan-control \
    -configuration "$fan_build_configuration" -destination 'generic/platform=macOS' \
    -derivedDataPath build ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO ${fan_version_arguments[@]+"${fan_version_arguments[@]}"} build

fan_app="build/Build/Products/$fan_build_configuration/Fan Control.app"
bash scripts/build-helper.sh "$fan_app/Contents/Library/HelperTools/FanControlHelper"
chmod -R a+rX "$fan_app"
if [[ -f "$fan_app/Contents/Library/LaunchDaemons/com.itswenb.fancontrol.helper.plist" ]]; then
    rm "$fan_app/Contents/Library/LaunchDaemons/com.itswenb.fancontrol.helper.plist"
fi
codesign --force --options runtime "${fan_sign_arguments[@]}" --identifier com.itswenb.fancontrol.helper \
    --sign "$fan_sign_identity" "$fan_app/Contents/Library/HelperTools/FanControlHelper"
fan_framework="$fan_app/Contents/Frameworks/Sparkle.framework"
if [[ ! -d "$fan_framework" ]]; then
    echo 'Sparkle.framework 未内嵌，已停止打包。' >&2
    exit 1
fi
# 必须从内到外签名，保留 Sparkle 工具原有的标识和沙箱权限。
for fan_component in \
    "$fan_framework/Versions/Current/XPCServices/Downloader.xpc" \
    "$fan_framework/Versions/Current/XPCServices/Installer.xpc" \
    "$fan_framework/Versions/Current/Autoupdate" \
    "$fan_framework/Versions/Current/Updater.app" \
    "$fan_framework"; do
    codesign --force "${fan_sign_arguments[@]}" --preserve-metadata=identifier,entitlements --sign "$fan_sign_identity" "$fan_component"
done
codesign --force --sign "$fan_sign_identity" "${fan_sign_arguments[@]}" "$fan_app"
codesign --verify --deep --strict "$fan_app"
echo "已构建：$fan_app"
echo '仅生成应用；不会注册服务、开启登录项或调节风扇。'
