#!/bin/bash
# 由 Tools/make-icon.swift 画出的 1024 母图切出各档尺寸，打包成 Resources/AppIcon.icns。
# 图标改了就重跑一次；make-app.sh 直接用生成好的 .icns，不依赖本脚本。
set -euo pipefail

cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift Tools/make-icon.swift "$WORK"

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
# iconutil 认死这套文件名，少一档都可能被拒。
for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
            "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" \
            "512:512x512" "1024:512x512@2x"; do
    px="${spec%%:*}"
    name="${spec##*:}"
    sips -z "$px" "$px" "$WORK/icon_1024.png" --out "$SET/icon_${name}.png" >/dev/null
done

mkdir -p Resources
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "已生成 Resources/AppIcon.icns（$(du -h Resources/AppIcon.icns | cut -f1)）"
