#!/bin/bash
# 用 swiftc 直接编译 SwiftUI 应用，并组装成可双击运行的 .app
# （本机仅有 Command Line Tools，SwiftPM 的 manifest 链接在此环境下失败，故直接调用 swiftc）
set -euo pipefail

APP_NAME="BatteryKiller"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT/build/$APP_NAME.app"
TOOLS_DIR="$ROOT/build/tools"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$TOOLS_DIR"

# 从 icons/ 下的 SVG 生成 App 图标与状态栏图标，保证图标随 SVG 一起更新
swiftc -O -o "$TOOLS_DIR/GenerateIcons" "$ROOT/tools/GenerateIcons.swift" -framework AppKit
"$TOOLS_DIR/GenerateIcons" "$ROOT/icons" "$APP_DIR/Contents/Resources"

swiftc -O -parse-as-library \
    -target arm64-apple-macos13.0 \
    -framework SwiftUI -framework AppKit -framework IOKit \
    -o "$APP_DIR/Contents/MacOS/$APP_NAME" \
    "$ROOT"/Sources/BatteryKiller/*.swift

cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

codesign --force --sign - "$APP_DIR" >/dev/null

echo "已生成：$APP_DIR"
