#!/usr/bin/env bash
# 编译并打包 DITKit.app
# 依赖：Xcode Command Line Tools 里的 clang
set -euo pipefail
cd "$(dirname "$0")"

SRC_DIR="DITKit"
OUT_DIR="build"
APP="$OUT_DIR/DITKit.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译"
# 源文件用通配符收集，新增工具页不用改这个脚本
clang -fobjc-arc -O2 -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
  -I"$SRC_DIR" \
  -framework Cocoa \
  -framework UniformTypeIdentifiers \
  -o "$APP/Contents/MacOS/DITKit" \
  "$SRC_DIR"/*.m

cp "$SRC_DIR/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 临时签名（避免 Gatekeeper 阻拦）"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
  echo "    签名跳过（不影响本地运行）"

echo "==> 完成：$(pwd)/$APP"
echo "    双击运行；命令行模式："
echo "    \"$APP/Contents/MacOS/DITKit\" --cli --lut <LUT> -- <视频...>"
echo "    \"$APP/Contents/MacOS/DITKit\" --cli --trim --start 00:00:10 --end 00:00:30 -- <视频...>"
