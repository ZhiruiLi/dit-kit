#!/usr/bin/env bash
# 用自检模式渲染各工具页 / 各外观的界面截图到 preview/
# 用法：./render-preview.sh [素材目录] [LUT 文件]
set -o pipefail
cd "$(dirname "$0")"

BIN="build/DITKit.app/Contents/MacOS/DITKit"
OUT="preview"
ASSETS="${1:-/tmp/dt/in}"
LUT="${2:-/tmp/dt/Look (Warm) [v2].cube}"

mkdir -p "$OUT"

# 素材：批量投喂两个视频（其中一个在子目录，用于验证「相对路径」布局）
VIDS="$ASSETS/片段 A.mp4|$ASSETS/sub/片段B.mp4"

render() {  # render <名称> <外观> <页号> <drop> [额外环境...]
    local name="$1" ap="$2" pg="$3" drop="$4"; shift 4
    local env_extra=("$@")
    # 每次渲染前先清空偏好，保证截图内容可复现
    defaults delete local.tools.ditkit >/dev/null 2>&1 || true
    env -i PATH="$PATH" HOME="$HOME" \
        DITKIT_APPEARANCE="$ap" \
        DITKIT_PAGE="$pg" \
        DITKIT_DROP="$drop" \
        DITKIT_LUT="$LUT" \
        DITKIT_SHOT="$PWD/$OUT/$name.png" \
        "${env_extra[@]}" \
        "$PWD/$BIN" --selftest >"/tmp/render-$name.log" 2>&1
    if [[ -s "$OUT/$name.png" ]]; then
        printf '%-14s %s  %s\n' "$name" "$(du -h "$OUT/$name.png" | cut -f1)" "$(file -b "$OUT/$name.png" | cut -c1-40)"
    else
        printf '%-14s 失败，见 /tmp/render-%s.log\n' "$name" "$name"
        tail -5 "/tmp/render-$name.log"
    fi
}

echo "==> 渲染 4 张界面截图"
render ui-dark    dark  0 "$VIDS"
render ui-light   light 0 "$VIDS"
render trim-dark  dark  1 "$VIDS" DITKIT_TRIM_START=00:00:03.000 DITKIT_TRIM_END=00:00:08.500
render trim-light light 1 "$VIDS" DITKIT_TRIM_START=00:00:03.000 DITKIT_TRIM_END=00:00:08.500
