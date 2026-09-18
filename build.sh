#!/bin/bash
# 用 swiftc 直接编译 SwiftUI 应用与特权助手，并组装成可双击运行的 .app
# （本机仅有 Command Line Tools，SwiftPM 的 manifest 链接在此环境下失败，故直接调用 swiftc）
set -euo pipefail

APP_NAME="BatteryKiller"
HELPER_NAME="bkhelper"
HELPER_LABEL="com.bkiller.batterykiller.helper"
HELPER_SOCKET="/var/run/$HELPER_LABEL.sock"
HELPER_STORE="/Library/PrivilegedHelperTools/$HELPER_LABEL"

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT/build/$APP_NAME.app"
TOOLS_DIR="$ROOT/build/tools"
SHIM_HEADER="$ROOT/Sources/Shared/SMCShim.h"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" \
         "$APP_DIR/Contents/Resources" \
         "$APP_DIR/Contents/Library/LaunchDaemons" \
         "$TOOLS_DIR"

# 从 icons/ 下的 SVG 生成 App 图标与状态栏图标，保证图标随 SVG 一起更新
swiftc -O -o "$TOOLS_DIR/GenerateIcons" "$ROOT/tools/GenerateIcons.swift" -framework AppKit
"$TOOLS_DIR/GenerateIcons" "$ROOT/icons" "$APP_DIR/Contents/Resources"

# 特权助手：与主程序共用 SMC 访问层，以 root 常驻，负责需要权限的 SMC 写入
# L10n 也要编进来：助手的错误文案会回传给主程序显示在界面上
swiftc -O \
    -target arm64-apple-macos13.0 \
    -import-objc-header "$SHIM_HEADER" \
    -framework Foundation -framework IOKit \
    -o "$APP_DIR/Contents/MacOS/$HELPER_NAME" \
    "$ROOT/Sources/BatteryKiller/SMC.swift" \
    "$ROOT/Sources/BatteryKiller/AdapterControl.swift" \
    "$ROOT/Sources/BatteryKiller/UnixSocket.swift" \
    "$ROOT/Sources/Shared/L10n.swift" \
    "$ROOT/Sources/Helper/main.swift"

# launchd 描述文件：主程序在首次授权时把它复制到 /Library/LaunchDaemons 并拉起
cat > "$APP_DIR/Contents/Library/LaunchDaemons/$HELPER_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$HELPER_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HELPER_STORE</string>
        <string>--socket</string>
        <string>$HELPER_SOCKET</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <!-- Interactive 可避免系统把常驻进程降级调度，导致响应变慢 -->
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardErrorPath</key>
    <string>/var/log/$HELPER_LABEL.log</string>
    <key>StandardOutPath</key>
    <string>/var/log/$HELPER_LABEL.log</string>
</dict>
</plist>
PLIST

swiftc -O -parse-as-library \
    -target arm64-apple-macos13.0 \
    -import-objc-header "$SHIM_HEADER" \
    -framework SwiftUI -framework AppKit -framework IOKit \
    -o "$APP_DIR/Contents/MacOS/$APP_NAME" \
    "$ROOT/Sources/Shared/L10n.swift" \
    "$ROOT"/Sources/BatteryKiller/*.swift

cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# 助手要单独签一次：它会被复制到 bundle 之外，以 root 身份运行
codesign --force --sign - "$APP_DIR/Contents/MacOS/$HELPER_NAME" >/dev/null
codesign --force --sign - "$APP_DIR" >/dev/null

echo "已生成：$APP_DIR"
