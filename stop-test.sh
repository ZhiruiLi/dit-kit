#!/usr/bin/env bash
# 回归「转换中点击停止」以及「正常跑完」两种收尾路径
#
# 停止复现手法：8 个文件 + 并发 1 → 1 个在跑、7 个排队。
#   cancel 若只杀活跃任务而漏掉排队任务，pump 的收尾条件
#   (_active==0 && _queue==0) 就永远不成立，onFinished 不触发，
#   界面会永久停在「正在停止…」。
#
# 前置：需要一个够长的测试素材（默认 /tmp/dt/big/长片段.mp4，30 秒 720p）。
#       没有的话可以自己造一个：
#         mkdir -p /tmp/dt/big && ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=25:duration=30 \
#           -f lavfi -i sine=frequency=440:duration=30 -c:v libx264 -preset veryfast -crf 20 \
#           -c:a aac -shortest /tmp/dt/big/长片段.mp4
#       素材与路径可用 SRC 环境变量覆盖。
#
# 用法：./stop-test.sh <标签> [lut|trim] [stop|full]
set -uo pipefail
cd "$(dirname "$0")"

TAG="${1:-run}"; PAGE_KIND="${2:-lut}"; MODE="${3:-stop}"
BIN="$PWD/build/DITKit.app/Contents/MacOS/DITKit"
DIR=/tmp/dt/stop-test
OUT=$DIR/out-$TAG-$PAGE_KIND-$MODE
LUT="${LUT:-/tmp/dt/Look (Warm) [v2].cube}"
SRC="${SRC:-/tmp/dt/big/长片段.mp4}"

[[ -x "$BIN" ]] || { echo "先跑 ./build.sh 生成 $BIN"; exit 1; }
# 注意：变量名要用 ${} 包起来——后面紧跟全角字符时，
# 不加花括号会被 shell 当成变量名的一部分（踩过）
[[ -f "$SRC" ]] || { echo "缺少测试素材：${SRC}（见脚本头部注释）"; exit 1; }
[[ -f "$LUT" ]] || { echo "缺少 LUT 文件：${LUT}（可用 LUT=... 覆盖）"; exit 1; }

# ---- 素材：8 份 30 秒 720p ----
mkdir -p "$DIR"
for i in 1 2 3 4 5 6 7 8; do
    [[ -f "$DIR/f$i.mp4" ]] || cp "$SRC" "$DIR/f$i.mp4"
done
rm -rf "$OUT"; mkdir -p "$OUT"
DROP=$(ls "$DIR"/f*.mp4 | paste -sd'|' -)

# ---- 偏好 ----
defaults delete local.tools.ditkit >/dev/null 2>&1
defaults write local.tools.ditkit lut.concurrency  -int 1
defaults write local.tools.ditkit lut.conflict     -int 2   # rename，避免重跑时被 skip
defaults write local.tools.ditkit lut.outMode      -int 1
defaults write local.tools.ditkit lut.outValue     -string "$OUT"
defaults write local.tools.ditkit trim.concurrency -int 1
defaults write local.tools.ditkit trim.conflict    -int 2
defaults write local.tools.ditkit trim.outMode     -int 1
defaults write local.tools.ditkit trim.outValue    -string "$OUT"

ENV=(DITKIT_APPEARANCE=dark DITKIT_DROP="$DROP" DITKIT_LUT="$LUT")
if [[ "$PAGE_KIND" == "trim" ]]; then
    ENV+=(DITKIT_PAGE=1 DITKIT_TRIM_START=00:00:03 DITKIT_TRIM_END=00:00:20)
    defaults write local.tools.ditkit trim.fastCopy -bool false   # 精确重编码，才有时间点停止
else
    ENV+=(DITKIT_PAGE=0)
fi

if [[ "$MODE" == "stop" ]]; then
    ENV+=(DITKIT_AUTOSTART=1 DITKIT_STOP_AFTER=1.2 DITKIT_SHOT_DELAY=8)
    DESC="1.2 秒时点停止，8 秒后看结果"
else
    ENV+=(DITKIT_AUTOSTART=1 DITKIT_SHOT_DELAY=28)
    DESC="一口气跑完，28 秒后看结果"
fi

echo "=== [$TAG / $PAGE_KIND / $MODE] 8 个文件 · 并发 1 · $DESC ==="
env "${ENV[@]}" "$BIN" --selftest >"/tmp/stop-$TAG.log" 2>&1

echo "--- 运行态（关键断言）---"
grep -E "运行态" "/tmp/stop-$TAG.log" | sed 's/^/  /' || echo "  (没拿到)"
echo "--- 产物 ---"
n=$(ls "$OUT" 2>/dev/null | wc -l | tr -d ' ')
echo "  共 $n 个"
echo "--- 残留 ffmpeg ---"
p=$(pgrep -f "out-$TAG" | wc -l | tr -d ' ')
echo "  数量: $p"
exit 0
