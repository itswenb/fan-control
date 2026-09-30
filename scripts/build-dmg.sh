#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

FANCONTROL_CONFIGURATION=Release bash scripts/build-app.sh

fan_app="build/Build/Products/Release/Fan Control.app"
fan_dmg="build/FanControl.dmg"
if [[ ! -s "$fan_app/Contents/Resources/AppIcon.icns" ]]; then
    echo '应用图标未生成，已停止打包。' >&2
    exit 1
fi
fan_stage="$(mktemp -d build/.fancontrol-dmg.XXXXXXXX)"
trap '/bin/rm -rf "$fan_stage"' EXIT
ditto "$fan_app" "$fan_stage/Fan Control.app"
ln -s /Applications "$fan_stage/Applications"
hdiutil create -volname "Fan Control" -srcfolder "$fan_stage" -format UDZO -ov "$fan_dmg"
echo "已生成：$fan_dmg"
