#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

fan_build_configuration="${FANCONTROL_CONFIGURATION:-Release}"
fan_sign_identity="${FANCONTROL_SIGN_IDENTITY:--}"
if [[ -n "${1:-}" ]]; then
    echo '用法：bash scripts/build-app.sh' >&2
    exit 1
fi

xcodebuild -quiet -project macs-fan-control.xcodeproj -scheme macs-fan-control \
    -configuration "$fan_build_configuration" -destination 'generic/platform=macOS' \
    -derivedDataPath build ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO build

fan_app="build/Build/Products/$fan_build_configuration/Fan Control.app"
bash scripts/build-helper.sh "$fan_app/Contents/Library/HelperTools/FanControlHelper"
if [[ -f "$fan_app/Contents/Library/LaunchDaemons/com.itswenb.fancontrol.helper.plist" ]]; then
    rm "$fan_app/Contents/Library/LaunchDaemons/com.itswenb.fancontrol.helper.plist"
fi
codesign --force --options runtime --timestamp=none --identifier com.itswenb.fancontrol.helper \
    --sign "$fan_sign_identity" "$fan_app/Contents/Library/HelperTools/FanControlHelper"
codesign --force --options runtime --timestamp=none --sign "$fan_sign_identity" "$fan_app"
codesign --verify --deep --strict "$fan_app"
echo "已构建：$fan_app"
echo '仅生成应用；不会注册服务、开启登录项或调节风扇。'
