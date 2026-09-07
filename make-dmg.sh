#!/bin/bash
# 把打好的 .app 封成可分发的 DMG，产物放桌面。
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(sed -n 's/.*static let string = "\(.*\)"/\1/p' Sources/AntiCaterCore/Version.swift)"
APP="$(cd ../../.. && pwd)/outputs/ANTICATER 原生版.app"
# 文件名必须是纯 ASCII：GitHub 上传附件时会把非 ASCII 字符替换成点号，
# 中文名传上去会变成 ANTICATER-.-1.0.dmg 这种东西。
DMG="$HOME/Desktop/ANTICATER-for-Mac-${VERSION}.dmg"

[ -d "$APP" ] || { echo "先跑 ./make-app.sh" >&2; exit 1; }

# 在临时目录里摆好内容：app + 一个「应用程序」快捷方式，拖进去就装好了。
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/应用程序"

rm -f "$DMG"
hdiutil create -volname "ANTICATER 原生版 ${VERSION}" \
    -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "已生成: ${DMG}"
