#!/usr/bin/env bash
# 用自检模式渲染各工具页 / 各外观的界面截图到 preview/
#
#   ./render-preview.sh [素材目录] [LUT 文件]
#
# 不给参数时，脚本会在临时目录里自己合成一套演示素材（两个视频 + 一个 LUT），
# 所以任何一台装了 ffmpeg 的机器都能原样重现 preview/ 下的图，不依赖本地现成的文件。
set -uo pipefail
cd "$(dirname "$0")"

FFMPEG="${FFMPEG:-$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)}"
BIN="build/DITKit.app/Contents/MacOS/DITKit"
OUT="preview"
DEMO="${1:-/tmp/ditkit-preview}"
LUT="${2:-$DEMO/Look (Warm) [v2].cube}"

if [ ! -x "$BIN" ]; then
    echo "找不到 $BIN，先跑 ./build.sh" >&2
    exit 1
fi

mkdir -p "$OUT"

# ---------- 演示素材 ----------
# 素材名里带空格、方括号、中文，顺带把「路径处理」这条也覆盖到。
if [ ! -s "$DEMO/in/片段 A.mp4" ] || [ ! -s "$DEMO/in/sub/片段 B.mp4" ]; then
    echo "==> 合成演示素材到 $DEMO"
    mkdir -p "$DEMO/in/sub"
    "$FFMPEG" -y -v error \
        -f lavfi -i "testsrc2=size=640x360:rate=25:duration=6" \
        -f lavfi -i "sine=frequency=440:duration=6" \
        -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p \
        -c:a aac -b:a 96k -shortest "$DEMO/in/片段 A.mp4" || exit 1
    "$FFMPEG" -y -v error \
        -f lavfi -i "smptebars=size=640x360:rate=25:duration=4" \
        -f lavfi -i "sine=frequency=660:duration=4" \
        -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p \
        -c:a aac -b:a 96k -shortest "$DEMO/in/sub/片段 B.mp4" || exit 1
fi

# 一个温和的暖调 2 点 cube（R 抬 6%、B 压 6%），够看出「这是个 LUT」即可
if [ ! -s "$LUT" ]; then
    cat >"$LUT" <<'EOF'
TITLE "Warm Look"
LUT_3D_SIZE 2
DOMAIN_MIN 0.0 0.0 0.0
DOMAIN_MAX 1.0 1.0 1.0
0.000 0.000 0.000
1.000 0.000 0.000
0.000 1.000 0.000
1.000 1.000 0.000
0.000 0.000 0.940
1.000 0.000 0.940
0.000 1.000 0.940
1.000 1.000 0.940
EOF
fi

VIDS="$DEMO/in/片段 A.mp4|$DEMO/in/sub/片段 B.mp4"

render() { # render <名称> <外观> <页号> <drop> [额外环境...]
    local name="$1" ap="$2" pg="$3" drop="$4"
    shift 4
    # 每次渲染前先清空偏好，保证截图内容可复现
    defaults delete local.tools.ditkit >/dev/null 2>&1 || true
    # 取帧缩略图缓存在 $TMPDIR，跨次残留会让截图带上上一轮的画面，先清掉
    rm -f "${TMPDIR:-/tmp}"/ditkit-thumb-*.png
    env -i PATH="$PATH" HOME="$HOME" \
        DITKIT_APPEARANCE="$ap" \
        DITKIT_PAGE="$pg" \
        DITKIT_DROP="$drop" \
        DITKIT_LUT="$LUT" \
        DITKIT_SHOT="$PWD/$OUT/$name.png" \
        "$@" \
        "$PWD/$BIN" --selftest >"/tmp/render-$name.log" 2>&1
    if [ -s "$OUT/$name.png" ]; then
        printf '%-12s %-6s %s\n' "$name" "$(du -h "$OUT/$name.png" | cut -f1)" \
            "$(file -b "$OUT/$name.png" | cut -c1-40)"
    else
        printf '%-12s 失败，见 /tmp/render-%s.log\n' "$name" "$name"
        tail -5 "/tmp/render-$name.log"
    fi
}

echo "==> 渲染 4 张界面截图到 $OUT/"
render ui-dark dark 0 "$VIDS"
render ui-light light 0 "$VIDS"
render trim-dark dark 1 "$VIDS" DITKIT_TRIM_START=00:00:03.000 DITKIT_TRIM_END=00:00:08.500
render trim-light light 1 "$VIDS" DITKIT_TRIM_START=00:00:03.000 DITKIT_TRIM_END=00:00:08.500
