#!/usr/bin/env bash
# 编译并打包 DITKit.app
# 依赖：Xcode Command Line Tools 里的 swiftc
set -euo pipefail
cd "$(dirname "$0")"

SRC_DIR="DITKit"
OUT_DIR="build"
APP="$OUT_DIR/DITKit.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译"
# 源文件用通配符收集，新增工具页不用改这个脚本。
#
# -swift-version 5：用 Swift 5 语言模式。这套代码的并发模型是 Process + DispatchQueue
#   + 回调；Swift 6 的严格并发检查会要求把它们改写成 async/await 并给跨线程共享的
#   状态标 Sendable —— 那是在换并发模型，不是换写法，真要做得单独开一版。
#
# -whole-module-optimization：多文件当成一个模块一次性编译，省编译时间，
#   也不给跨文件调用留未优化边界。
swiftc \
  -swift-version 5 \
  -O -whole-module-optimization \
  -framework Cocoa \
  -framework UniformTypeIdentifiers \
  -o "$APP/Contents/MacOS/DITKit" \
  "$SRC_DIR"/*.swift

cp "$SRC_DIR/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 临时签名（避免 Gatekeeper 阻拦）"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
  echo "    签名跳过（不影响本地运行）"

echo "==> 完成：$(pwd)/$APP"
echo "    双击运行；命令行模式："
echo "    \"$APP/Contents/MacOS/DITKit\" --cli --lut <LUT> -- <视频...>"
echo "    \"$APP/Contents/MacOS/DITKit\" --cli --trim --start 00:00:10 --end 00:00:30 -- <视频...>"
echo "    \"$APP/Contents/MacOS/DITKit\" --cli --audio --start 00:00:10 --end 00:00:30 -- <文件...>"
echo "    \"$APP/Contents/MacOS/DITKit\" --cli --mask --image <图片> -- <视频...>"
echo "    \"$APP/Contents/MacOS/DITKit\" --help     查看全部用法"
