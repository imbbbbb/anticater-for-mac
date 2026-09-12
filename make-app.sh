#!/bin/bash
# 把 SwiftPM 产物打包成可双击运行的 ANTICATER.app（原生 arm64，无需任何系统权限）
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-release}"
OUT="$(cd ../../.. && pwd)/outputs"
APP="$OUT/ANTICATER 原生版.app"

# 版本号只有一个来源：Sources/AntiCaterCore/Version.swift。
# 从那里抠出来填进 Info.plist，免得 app 里显示的和 GitHub 上发的对不上。
VERSION="$(sed -n 's/.*static let string = "\(.*\)"/\1/p' Sources/AntiCaterCore/Version.swift)"
if [ -z "$VERSION" ]; then echo "读不到版本号，检查 Version.swift" >&2; exit 1; fi

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/AntiCaterApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AntiCater"

# 把只读的 dump 工具一起装进包里。它带 --diagnose，是「插上了却连不上」时
# 唯一能拿到证据的手段；只放在源码仓库里等于普通用户用不上。
cp "$(dirname "$BIN")/anticater-dump" "$APP/Contents/MacOS/anticater-dump"

# 图标由 Tools/make-icon.sh 生成并入库。缺了也能打包，只是 Dock 里是白板。
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
    echo "警告：Resources/AppIcon.icns 不存在，先跑 ./Tools/make-icon.sh" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>ANTICATER</string>
    <key>CFBundleDisplayName</key>       <string>ANTICATER 原生版</string>
    <key>CFBundleExecutable</key>        <string>AntiCater</string>
    <key>CFBundleIdentifier</key>        <string>io.github.imbbbbb.anticater</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>非官方第三方实现，PolyForm Noncommercial 1.0.0 授权</string>
</dict>
</plist>
PLIST

codesign -f -s - "$APP"

echo "已生成: ${APP}（版本 ${VERSION}）"
lipo -archs "$APP/Contents/MacOS/AntiCater"
