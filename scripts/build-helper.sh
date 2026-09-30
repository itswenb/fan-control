#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 1 ]]; then
    echo '用法：bash scripts/build-helper.sh 输出路径' >&2
    exit 1
fi
fan_helper_output="$1"
swift build --scratch-path .build --configuration release --product FanControlHelper --triple arm64-apple-macosx14.0
fan_bin_path="$(swift build --scratch-path .build --configuration release --show-bin-path --triple arm64-apple-macosx14.0)"
mkdir -p "$(dirname "$fan_helper_output")"
cp "$fan_bin_path/FanControlHelper" "$fan_helper_output"
