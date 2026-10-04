#!/usr/bin/env bash
# 合成测试素材。全部用 ffmpeg 的 lavfi 生成，不依赖任何外部文件，
# 因此任何一台装了 ffmpeg 的机器都能得到同样的素材。
#
# 核心是「时间码标尺」：每 BAND 秒换一种固定纯色（10 色循环）。有了它，
# 「裁剪起点对不对」「输出的是不是请求的那一段」就变成
# 「第几段、什么颜色」这样的精确断言，不必靠肉眼或算像素差。
#
# 两个刻意的设计：
#   1) 每段只有 0.5 秒，短于 1 秒的关键帧间隔 —— 这样「精确重编码」与
#      「快退到关键帧」的差异才可观测（否则起点落在关键帧上，两者一样）。
#   2) 关掉场景切换插关键帧（scenecut=0），保证关键帧严格落在整秒，
#      上面那条假设才成立。
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="$TESTS_DIR/work/fixtures"
FFMPEG="${FFMPEG:-$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)}"

BAND=0.5 # 每段标尺时长（秒），与 tests/lib.sh 里的 BAND 必须一致

# 标尺调色板，10 色循环。数值刻意避开 0/255 两端，减少 YUV 往返与有损编码的漂移。
RULER_RGB=(
    "204 32 32"    # 0 红
    "32 204 32"    # 1 绿
    "32 32 204"    # 2 蓝
    "204 204 32"   # 3 黄
    "204 32 204"   # 4 品红
    "32 204 204"   # 5 青
    "238 238 238"  # 6 白
    "18 18 18"     # 7 黑
    "128 128 128"  # 8 中灰
    "255 128 0"    # 9 橙
)

mkdir -p "$FIX"
echo "==> 生成测试素材到 $FIX"

# 时间码标尺：secs 秒，每 BAND 秒一段纯色，关键帧严格每秒一个
build_ruler() {
    local out="$1" w="$2" h="$3" fps="$4" secs="$5"
    local n
    n=$(awk -v s="$secs" -v b="$BAND" 'BEGIN { printf "%d", s / b }')
    local args=() fc="" i=0
    while [ "$i" -lt "$n" ]; do
        local r g b hex
        read -r r g b <<<"${RULER_RGB[$((i % 10))]}"
        printf -v hex '%02X%02X%02X' "$r" "$g" "$b"
        args+=(-f lavfi -i "color=c=0x${hex}:s=${w}x${h}:r=${fps}:d=${BAND}")
        fc+="[$i:v]"
        i=$((i + 1))
    done
    fc+="concat=n=${n}:v=1:a=0[v]"
    "$FFMPEG" -y -v error "${args[@]}" -f lavfi -i "sine=frequency=440:duration=${secs}" \
        -filter_complex "$fc" -map "[v]" -map "${n}:a" \
        -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p \
        -g "$fps" -keyint_min "$fps" -sc_threshold 0 \
        -c:a aac -b:a 96k -shortest "$out"
}

# 音高标尺：每 BAND 秒换一个纯音（TONE_BASE + TONE_STEP*i Hz，10 个一循环）。
# 与画面标尺同一个思路 —— 有了它，「提取的音频区间对不对」可以变成
# 「第几段音高」这样的精确断言，而不是「听起来差不多」。
TONE_BASE=300
TONE_STEP=100
TONE_COUNT=10
AUDIO_RATE=48000

build_tone_ruler() {
    local out="$1" w="$2" h="$3" fps="$4" secs="$5"
    local n
    n=$(awk -v s="$secs" -v b="$BAND" 'BEGIN { printf "%d", s / b }')
    local vargs=() aargs=() fcv="" fca="" i=0
    while [ "$i" -lt "$n" ]; do
        local r g b hex f
        read -r r g b <<<"${RULER_RGB[$((i % 10))]}"
        printf -v hex '%02X%02X%02X' "$r" "$g" "$b"
        f=$((TONE_BASE + TONE_STEP * (i % TONE_COUNT)))
        vargs+=(-f lavfi -i "color=c=0x${hex}:s=${w}x${h}:r=${fps}:d=${BAND}")
        aargs+=(-f lavfi -i "sine=frequency=${f}:sample_rate=${AUDIO_RATE}:duration=${BAND}")
        fcv+="[$i:v]"
        fca+="[$((n + i)):a]"
        i=$((i + 1))
    done
    # 画面与声音各自 concat：视频输入在前、音频输入在后，所以两个 filter 各用一段
    fcv+="concat=n=${n}:v=1:a=0[v]"
    fca+="concat=n=${n}:v=0:a=1[a]"
    "$FFMPEG" -y -v error "${vargs[@]}" "${aargs[@]}" \
        -filter_complex "${fcv};${fca}" -map "[v]" -map "[a]" \
        -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p \
        -g "$fps" -keyint_min "$fps" -sc_threshold 0 \
        -c:a aac -b:a 128k "$out"
}

# 调色板真源（生成端与断言端共用）
i=0
for c in "${RULER_RGB[@]}"; do
    printf '%s\t%s\n' "$i" "$(echo "$c" | tr ' ' '\t')" >>"$FIX/colors.tsv.tmp"
    i=$((i + 1))
done
mv "$FIX/colors.tsv.tmp" "$FIX/colors.tsv"
# 段长写进 manifest，断言端读它来算「某时刻应该是第几号颜色」，
# 避免两处各写一个常数、改了这边忘了那边
printf '%s\n' "$BAND" >"$FIX/band.txt"
# 音高标尺的三个常数同理
printf '%s %s %s\n' "$TONE_BASE" "$TONE_STEP" "$TONE_COUNT" >"$FIX/tones.txt"

# A：主素材，10 秒 320x180@30（裁剪精度、LUT、批量都用它）
build_ruler "$FIX/ruler_a.mp4" 320 180 30 10

# B：规格不同，用来验证批量时各任务互不干扰，8 秒 480x270@20
build_ruler "$FIX/ruler_b.mp4" 480 270 20 8

# C：音高标尺，6 秒 —— 提取音频的区间断言用它（画面同时验证「视频进、音频出」）。
# 6 秒 = 12 段，音高正好走完一轮多一点点。
build_tone_ruler "$FIX/tone_ruler.mp4" 320 180 30 6

# C2：同一段音高的纯音频版本，验证「音频进、音频出」也能用
"$FFMPEG" -y -v error -i "$FIX/tone_ruler.mp4" -vn -c:a copy "$FIX/tone_ruler.m4a"

# 纯色素材：整段一个颜色，LUT 断言用它，帧均值最稳定
"$FFMPEG" -y -v error \
    -f lavfi -i "color=c=0x804020:s=320x180:r=25:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -c:v libx264 -preset veryfast -crf 12 -pix_fmt yuv420p \
    -c:a aac -b:a 96k -shortest "$FIX/solid.mp4"

# 长素材：停更测试用。内容无所谓，但必须够大够长，保证一个任务不会在
# 1~2 秒内跑完，否则构造不出「1 个在跑、N 个排队」的场景。
"$FFMPEG" -y -v error \
    -f lavfi -i "testsrc2=size=1280x720:rate=25:duration=20" \
    -f lavfi -i "sine=frequency=440:duration=20" \
    -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p \
    -c:a aac -b:a 96k -shortest "$FIX/long.mp4"

# ---------- LUT ----------
# R↔B 通道互换。这个映射是线性的，而 2 点 cube 的三线性插值能精确复现
# 线性映射 —— 所以「输入 (R,G,B) 应当得到 (B,G,R)」是一条可精确断言的
# 强条件，能真正证明 LUT 被正确套用，而不是只看颜色「变了没」。
cat >"$FIX/swap.cube" <<'EOF'
TITLE "R-B swap (size 2, linear)"
LUT_3D_SIZE 2
DOMAIN_MIN 0.0 0.0 0.0
DOMAIN_MAX 1.0 1.0 1.0
0.0 0.0 0.0
0.0 0.0 1.0
0.0 1.0 0.0
0.0 1.0 1.0
1.0 0.0 0.0
1.0 0.0 1.0
1.0 1.0 0.0
1.0 1.0 1.0
EOF

cat >"$FIX/identity.cube" <<'EOF'
TITLE "identity (size 2)"
LUT_3D_SIZE 2
DOMAIN_MIN 0.0 0.0 0.0
DOMAIN_MAX 1.0 1.0 1.0
0.0 0.0 0.0
1.0 0.0 0.0
0.0 1.0 0.0
1.0 1.0 0.0
0.0 0.0 1.0
1.0 0.0 1.0
0.0 1.0 1.0
1.0 1.0 1.0
EOF

# 纯色素材的实际颜色（供断言端读取）
printf '128\t64\t32\n' >"$FIX/solid.tsv"

for f in ruler_a.mp4 ruler_b.mp4 tone_ruler.mp4 tone_ruler.m4a solid.mp4 long.mp4 \
    swap.cube identity.cube colors.tsv band.txt tones.txt; do
    [ -s "$FIX/$f" ] || {
        echo "生成失败: $f" >&2
        exit 1
    }
    printf '    %-14s %s\n' "$f" "$(du -h "$FIX/$f" | cut -f1)"
done

date >"$FIX/.stamp"
echo "==> 素材就绪"
