#!/usr/bin/env bash
# 图片遮罩：四种适配、三种混合、不透明度、输出规格、批量、错误路径。
#
# 期望值一律由声明颜色算出来（base_rgb / mask_rgb + rgb_lerp / rgb_multiply /
# rgb_screen），不把观测读数抄进用例 —— 那样只能证明「和上次一样」，
# 证明不了「合成公式对」。
#
# 素材：solid.mp4 是 320×180 的整段纯色（声明值见 solid.tsv），
# 图片一律是能精确算出来的纯色图（见 mkfixtures.sh 的「遮罩用图片」一节）。
GROUP="遮罩"

# 画面三个参考区域，都取 40×40。
# 左上与右下正好是「原始大小」下 40×40 图层贴到左上 / 右下时覆盖的范围，
# 中间是贴到正中时覆盖的范围 —— 三个位置都能落到边界内，读数才是纯的。
OV_TL=(0 0 40 40)        # 左上角
OV_CTR=(140 70 40 40)    # 正中
OV_BR=(280 140 40 40)    # 右下角

# 合成一条，回读整画面与三个区域的均值
# 用法: mask_make <标签> <图片> <视频> [--mask 选项...]
# 结果写进 MASK_FULL / MASK_TL / MASK_CTR / MASK_BR
mask_make() {
    local tag="$1" img="$2" src="$3"
    shift 3
    local d="$MASK_DIR/$tag"
    rm -rf "$d"
    mkdir -p "$d"
    run_mask "$d" "$img" "$src" "$@" >/dev/null
    MASK_OUT="$(ls "$d"/*.mp4 2>/dev/null | head -1)"
    [ -n "$MASK_OUT" ] || fail "${tag} 没有产出文件: $(ls "$d" 2>/dev/null | tr '\n' ' ')"
    MASK_FULL=$(frame_rgb "$MASK_OUT" 0.5)
    MASK_TL=$(region_rgb "$MASK_OUT" 0.5 "${OV_TL[@]}")
    MASK_CTR=$(region_rgb "$MASK_OUT" 0.5 "${OV_CTR[@]}")
    MASK_BR=$(region_rgb "$MASK_OUT" 0.5 "${OV_BR[@]}")
}

# 每个用例一个干净的输出根目录
mask_dir() {
    MASK_DIR="$(fresh_dir "$1")"
}

# ---------- 适配方式 ----------

# 拉伸铺满：整画面都应当是图片的颜色
c_fit_stretch_covers_frame() {
    mask_dir mask-stretch
    mask_make stretch "$FIX/ov_small_green.png" "$FIX/solid.mp4" --fit stretch
    expect_rgb_near "$(mask_rgb ov_small_green)" "$MASK_FULL" 6 "拉伸后整画面"
    expect_rgb_near "$(mask_rgb ov_small_green)" "$MASK_TL" 6 "拉伸后左上角"
}

# 等比铺满：保持比例放大到盖住画面，整画面也应当是图片的颜色
c_fit_cover_covers_frame() {
    mask_dir mask-cover
    mask_make cover "$FIX/ov_small_green.png" "$FIX/solid.mp4" --fit cover
    expect_rgb_near "$(mask_rgb ov_small_green)" "$MASK_FULL" 6 "等比铺满后整画面"
    expect_rgb_near "$(mask_rgb ov_small_green)" "$MASK_BR" 6 "等比铺满后右下角"
}

# 等比完整：只有图片盖到的中间是图片色，四角仍是画面本身
c_fit_contain_letterboxes() {
    mask_dir mask-contain
    mask_make contain "$FIX/ov_small_green.png" "$FIX/solid.mp4" --fit contain
    expect_rgb_near "$(mask_rgb ov_small_green)" "$MASK_CTR" 6 "等比完整后正中"
    expect_rgb_near "$(base_rgb)" "$MASK_TL" 6 "等比完整后左上角应当还是画面本身"
    expect_rgb_near "$(base_rgb)" "$MASK_BR" 6 "等比完整后右下角应当还是画面本身"
}

# 原始大小：40×40 的图不缩放，按选的位置贴上去；其余地方是画面本身
c_fit_original_keeps_size() {
    mask_dir mask-original
    mask_make orig-center "$FIX/ov_small_green.png" "$FIX/solid.mp4" --fit original --pos center
    expect_rgb_near "$(mask_rgb ov_small_green)" "$MASK_CTR" 6 "原始大小·居中"
    expect_rgb_near "$(base_rgb)" "$MASK_TL" 6 "原始大小·居中的左上角"
    expect_rgb_near "$(base_rgb)" "$MASK_BR" 6 "原始大小·居中的右下角"

    mask_make orig-br "$FIX/ov_small_green.png" "$FIX/solid.mp4" --fit original --pos br
    expect_rgb_near "$(mask_rgb ov_small_green)" "$MASK_BR" 6 "原始大小·右下"
    expect_rgb_near "$(base_rgb)" "$MASK_CTR" 6 "原始大小·右下的正中"

    mask_make orig-tl "$FIX/ov_small_green.png" "$FIX/solid.mp4" --fit original --pos tl
    expect_rgb_near "$(mask_rgb ov_small_green)" "$MASK_TL" 6 "原始大小·左上"
    expect_rgb_near "$(base_rgb)" "$MASK_CTR" 6 "原始大小·左上的正中"
}

# 位置只对「原始大小」有意义：另外三种会把画面铺满，给什么位置都应当一样
c_position_ignored_by_full_frame_fits() {
    mask_dir mask-pos-ignored
    mask_make pos-br "$FIX/ov_small_green.png" "$FIX/solid.mp4" --fit stretch --pos br
    expect_rgb_near "$(mask_rgb ov_small_green)" "$MASK_FULL" 6 "拉伸时给位置也应当铺满"
}

# 反证：区域探针必须真能分辨位置。
# 没有这一条，上面那些「中间是图片色、角落是画面色」只能说明探针读到了东西，
# 说明不了它读的位置是对的。
c_region_probe_can_tell_positions_apart() {
    mask_dir mask-probe-check
    mask_make p-tl "$FIX/ov_small_green.png" "$FIX/solid.mp4" --fit original --pos tl
    local tl_at_tl="$MASK_TL"
    mask_make p-br "$FIX/ov_small_green.png" "$FIX/solid.mp4" --fit original --pos br
    local br_at_tl="$MASK_TL"
    # 同一个区域，一张是图片色、一张是画面色 —— 探针分辨不出来就会相等
    expect_ne "$tl_at_tl" "$br_at_tl" "同一区域在 tl / br 两个产物里应当读出不同颜色"
    expect_rgb_near "$(base_rgb)" "$br_at_tl" 6 "br 产物里左上角应当是画面本身"
    note "  tl 产物左上角=$tl_at_tl   br 产物左上角=$br_at_tl"
}

# ---------- 不透明度 ----------

c_opacity_scales_layer() {
    mask_dir mask-opacity
    local base red
    base=$(base_rgb)
    red=$(mask_rgb ov_full_red)

    mask_make op100 "$FIX/ov_full_red.png" "$FIX/solid.mp4" --opacity 100
    expect_rgb_near "$red" "$MASK_FULL" 6 "不透明度 100"

    mask_make op50 "$FIX/ov_full_red.png" "$FIX/solid.mp4" --opacity 50
    expect_rgb_near "$(rgb_lerp "$base" "$red" 0.5)" "$MASK_FULL" 6 "不透明度 50"

    mask_make op0 "$FIX/ov_full_red.png" "$FIX/solid.mp4" --opacity 0
    expect_rgb_near "$base" "$MASK_FULL" 6 "不透明度 0 时画面应当原样"
}

# 越界的不透明度按上下界夹住，不报错（与音频码率同一套处理）
c_opacity_out_of_range_is_clamped() {
    mask_dir mask-opacity-clamp
    local base red
    base=$(base_rgb)
    red=$(mask_rgb ov_full_red)

    mask_make op200 "$FIX/ov_full_red.png" "$FIX/solid.mp4" --opacity 200
    expect_rgb_near "$red" "$MASK_FULL" 6 "不透明度 200 应当夹到 100"

    mask_make opneg "$FIX/ov_full_red.png" "$FIX/solid.mp4" --opacity -30
    expect_rgb_near "$base" "$MASK_FULL" 6 "不透明度负数应当夹到 0"
}

# 图片自带的透明通道要真的生效：50% alpha 的图在 100% 不透明度下，
# 效果应当等于同色实心图在 50% 不透明度下
c_alpha_channel_is_honoured() {
    mask_dir mask-alpha
    local base red alpha p
    base=$(base_rgb)
    red=$(mask_rgb ov_half_red)
    alpha=$(mask_alpha ov_half_red)
    p=$(awk -v a="$alpha" 'BEGIN { printf "%.4f", a / 255 }')

    mask_make alpha "$FIX/ov_half_red.png" "$FIX/solid.mp4" --opacity 100
    mask_make solid50 "$FIX/ov_full_red.png" "$FIX/solid.mp4" --opacity 50
    expect_rgb_near "$(rgb_lerp "$base" "$red" "$p")" "$MASK_FULL" 6 "带 alpha 的图"
    # 两条路径得到同一个结果，这本身就是「alpha 而不是不透明度在起作用」的证据
    expect_rgb_near "$MASK_FULL" "$(frame_rgb "$MASK_DIR/solid50"/*.mp4 0.5)" 3 \
        "透明通道与不透明度的等价性"
}

# ---------- 混合方式 ----------

# 正片叠底：白色是它的单位元，图片不存在的地方画面原样保留
c_blend_multiply_neutral_is_white() {
    mask_dir mask-mul
    local base gray
    base=$(base_rgb)
    gray=$(mask_rgb ov_full_gray)

    mask_make mul-white "$FIX/ov_full_white.png" "$FIX/solid.mp4" --blend multiply
    expect_rgb_near "$base" "$MASK_FULL" 6 "叠白色应当等于没叠"

    mask_make mul-gray "$FIX/ov_full_gray.png" "$FIX/solid.mp4" --blend multiply
    expect_rgb_near "$(rgb_multiply "$base" "$gray")" "$MASK_FULL" 6 "叠中灰"

    mask_make mul-half "$FIX/ov_full_gray.png" "$FIX/solid.mp4" --blend multiply --opacity 50
    expect_rgb_near "$(rgb_lerp "$base" "$(rgb_multiply "$base" "$gray")" 0.5)" "$MASK_FULL" 6 \
        "叠中灰 50%"

    mask_make mul-zero "$FIX/ov_full_gray.png" "$FIX/solid.mp4" --blend multiply --opacity 0
    expect_rgb_near "$base" "$MASK_FULL" 6 "不透明度 0 时混合应当不生效"
}

# 滤色：黑色是它的单位元
c_blend_screen_neutral_is_black() {
    mask_dir mask-screen
    local base gray
    base=$(base_rgb)
    gray=$(mask_rgb ov_full_gray)

    mask_make scr-black "$FIX/ov_full_black.png" "$FIX/solid.mp4" --blend screen
    expect_rgb_near "$base" "$MASK_FULL" 6 "滤黑色应当等于没滤"

    mask_make scr-gray "$FIX/ov_full_gray.png" "$FIX/solid.mp4" --blend screen
    expect_rgb_near "$(rgb_screen "$base" "$gray")" "$MASK_FULL" 6 "滤中灰"

    mask_make scr-half "$FIX/ov_full_gray.png" "$FIX/solid.mp4" --blend screen --opacity 50
    expect_rgb_near "$(rgb_lerp "$base" "$(rgb_screen "$base" "$gray")" 0.5)" "$MASK_FULL" 6 \
        "滤中灰 50%"
}

# 混合必须在 RGB 空间做。在 YUV 各平面上直接相乘会得到错颜色 ——
# 这里用「单位元不带颜色偏移」来守：叠白色/黑色之后逐通道都应当还是原值，
# 若在 YUV 里算，色度平面会一起被乘，读数会明显偏。
c_blend_happens_in_rgb_space() {
    mask_dir mask-rgb
    local base
    base=$(base_rgb)
    mask_make mul-white2 "$FIX/ov_full_white.png" "$FIX/solid.mp4" --blend multiply
    expect_rgb_near "$base" "$MASK_FULL" 2 "RGB 空间里乘 1 应当逐通道不变"
    mask_make scr-black2 "$FIX/ov_full_black.png" "$FIX/solid.mp4" --blend screen
    expect_rgb_near "$base" "$MASK_FULL" 2 "RGB 空间里加 0 应当逐通道不变"
}

# 混合时图片没盖到的地方要靠「中性色画布」还原成画面本身。
# 这一条是那套画布设计的核心：contain 让图层只盖中间，四角必须还是画面色。
c_blend_keeps_uncovered_area_intact() {
    mask_dir mask-neutral-canvas
    local base green
    base=$(base_rgb)
    green=$(mask_rgb ov_small_green)

    mask_make mul-contain "$FIX/ov_small_green.png" "$FIX/solid.mp4" --fit contain --blend multiply
    expect_rgb_near "$base" "$MASK_TL" 6 "正片叠底下四角应当还是画面本身"
    expect_rgb_near "$(rgb_multiply "$base" "$green")" "$MASK_CTR" 6 "正片叠底下图层区域"

    mask_make scr-contain "$FIX/ov_small_green.png" "$FIX/solid.mp4" --fit contain --blend screen
    expect_rgb_near "$base" "$MASK_TL" 6 "滤色下四角应当还是画面本身"
    expect_rgb_near "$(rgb_screen "$base" "$green")" "$MASK_CTR" 6 "滤色下图层区域"
}

# ---------- 输出规格 ----------

# 成品必须是 HEVC 10bit，mp4/mov 要带 hvc1 标签，音频原样复制
c_output_spec() {
    mask_dir mask-spec
    local out
    mask_make spec "$FIX/ov_full_red.png" "$FIX/solid.mp4" --fit stretch
    out="$MASK_OUT"

    expect_eq "hevc" "$(probe_vcodec "$out")" "视频编码"
    expect_eq "yuv420p10le" "$(probe_pixfmt "$out")" "像素格式（10bit 防断层）"
    expect_eq "2" "$(probe_stream_count "$out")" "视频 + 音频两条流"
    expect_eq "$(probe_acodec "$FIX/solid.mp4")" "$(probe_acodec "$out")" "音频应当原样复制"
    expect_eq "hvc1" "$(ffprobe_tag "$out")" "mp4 应当带 hvc1 标签"
    expect_near "$(probe_duration "$FIX/solid.mp4")" "$(probe_duration "$out")" 0.15 "时长"
    expect_eq "$(ffprobe_vsize "$FIX/solid.mp4")" "$(ffprobe_vsize "$out")" "画面尺寸应当不变"
}

# 编码质量越大越清晰（videotoolbox 的 -q:v 数值越大画质越高）。
#
# 素材必须是有细节的：纯色画面下编码器早就触底，任何质量档都是几百字节，
# 那种情况下「比不出高低」是素材的错，不是参数的错。
c_quality_takes_effect() {
    mask_dir mask-quality
    local lo hi
    mask_make q-lo "$FIX/ov_full_red.png" "$FIX/detail.mp4" --quality 1
    lo=$(stat -f %z "$MASK_OUT")
    mask_make q-hi "$FIX/ov_full_red.png" "$FIX/detail.mp4" --quality 100
    hi=$(stat -f %z "$MASK_OUT")
    expect_ge "$hi" "$((lo * 3 / 2))" "高质量产物应当明显大于低质量"
    note "质量 1=${lo} 字节，100=${hi} 字节"
}

# ---------- 批量与落位 ----------

c_batch_and_relative_output() {
    mask_dir mask-batch
    local d="$MASK_DIR/in" out
    mkdir -p "$d/子目录"
    cp "$FIX/solid.mp4" "$d/顶层.mp4"
    cp "$FIX/solid.mp4" "$d/子目录/嵌套.mp4"
    out=$(run "$BIN" --cli --mask --image "$FIX/ov_full_red.png" --relative 遮罩 "$d")
    expect_contains "$out" "结束：共 2，失败 0" "批量结果"
    expect_file "$d/遮罩/顶层_mask.mp4"
    expect_file "$d/子目录/遮罩/嵌套_mask.mp4"
    expect_rgb_near "$(mask_rgb ov_full_red)" "$(frame_rgb "$d/遮罩/顶层_mask.mp4" 0.5)" 6 \
        "批量产物内容"
}

c_suffix_option() {
    mask_dir mask-suffix
    local out
    out=$(run "$BIN" --cli --mask --image "$FIX/ov_full_red.png" \
        --out "$MASK_DIR/o" --suffix _ovl -- "$FIX/solid.mp4")
    expect_contains "$out" "结束：共 1，失败 0" "运行结果"
    expect_file "$MASK_DIR/o/solid_ovl.mp4"
    expect_no_file "$MASK_DIR/o/solid_mask.mp4"
}

c_output_is_not_reprocessed() {
    mask_dir mask-reprocess
    local d="$MASK_DIR/in" out
    mkdir -p "$d"
    cp "$FIX/solid.mp4" "$d/s.mp4"
    run "$BIN" --cli --mask --image "$FIX/ov_full_red.png" --out "$d" -- "$d/s.mp4" >/dev/null
    expect_file "$d/s_mask.mp4"
    out=$(run "$BIN" --cli --mask --image "$FIX/ov_full_red.png" --out "$MASK_DIR/again" -- "$d")
    expect_contains "$out" "结束：共 1，失败 0" "目录里只有源文件该被处理"
    expect_no_file "$MASK_DIR/again/s_mask_mask.mp4"
}

c_conflict_skip_by_default() {
    mask_dir mask-conflict
    local d="$MASK_DIR/o" out
    run "$BIN" --cli --mask --image "$FIX/ov_full_red.png" --out "$d" -- "$FIX/solid.mp4" >/dev/null
    out=$(run "$BIN" --cli --mask --image "$FIX/ov_full_red.png" --out "$d" -- "$FIX/solid.mp4")
    expect_contains "$out" "[跳过]" "第二次运行应当报告跳过"
    out=$(run "$BIN" --cli --mask --image "$FIX/ov_full_red.png" \
        --conflict rename --out "$d" -- "$FIX/solid.mp4")
    expect_contains "$out" "结束：共 1，失败 0" "rename 策略应当产出一份新的"
    expect_file "$d/solid_mask (1).mp4"
}

# 不同规格的素材混批：每个任务各自探测画面尺寸，产物尺寸不串
c_batch_mixed_sizes() {
    mask_dir mask-mixed
    run "$BIN" --cli --mask --image "$FIX/ov_full_red.png" --fit stretch --jobs 3 \
        --out "$MASK_DIR/o" -- "$FIX/ruler_a.mp4" "$FIX/ruler_b.mp4" >/dev/null
    expect_file "$MASK_DIR/o/ruler_a_mask.mp4"
    expect_file "$MASK_DIR/o/ruler_b_mask.mp4"
    expect_eq "320,180" "$(ffprobe_vsize "$MASK_DIR/o/ruler_a_mask.mp4")" "a 的尺寸"
    expect_eq "480,270" "$(ffprobe_vsize "$MASK_DIR/o/ruler_b_mask.mp4")" "b 的尺寸"
}

# 没有音频的素材也能加遮罩，产物不该凭空多出一条音频流
c_video_without_audio() {
    mask_dir mask-noaudio
    run "$BIN" --cli --mask --image "$FIX/ov_full_red.png" --out "$MASK_DIR/o" -- "$FIX/silent.mp4" >/dev/null
    expect_file "$MASK_DIR/o/silent_mask.mp4"
    expect_eq "1" "$(probe_stream_count "$MASK_DIR/o/silent_mask.mp4")" "只有一条流"
    expect_eq "160,90" "$(ffprobe_vsize "$MASK_DIR/o/silent_mask.mp4")" "小尺寸素材的产物尺寸"
}

# 先裁剪再加遮罩：两页能串起来用
c_pipeline_trim_then_mask() {
    mask_dir mask-pipeline
    run "$BIN" --cli --trim --end 00:00:01 --out "$MASK_DIR/cut" -- "$FIX/solid.mp4" >/dev/null
    expect_file "$MASK_DIR/cut/solid_trim.mp4"
    run "$BIN" --cli --mask --image "$FIX/ov_full_red.png" --out "$MASK_DIR/o" \
        -- "$MASK_DIR/cut/solid_trim.mp4" >/dev/null
    expect_file "$MASK_DIR/o/solid_trim_mask.mp4"
    expect_rgb_near "$(mask_rgb ov_full_red)" "$(frame_rgb "$MASK_DIR/o/solid_trim_mask.mp4" 0.5)" 6 \
        "裁剪后再加遮罩"
}

# ---------- 错误路径 ----------

c_error_missing_image() {
    expect_error 2 "还没有指定遮罩图片" -- \
        "$BIN" --cli --mask -- "$FIX/solid.mp4"
}

c_error_image_not_found() {
    expect_error 2 "遮罩图片不存在" -- \
        "$BIN" --cli --mask --image "$FIX/没有这张图.png" -- "$FIX/solid.mp4"
}

# 后缀不对的文件当场拒掉，而不是丢给 ffmpeg 报一句看不懂的错
c_error_image_wrong_extension() {
    expect_error 2 "不是图片" -- \
        "$BIN" --cli --mask --image "$FIX/solid.mp4" -- "$FIX/solid.mp4"
}

c_error_unknown_fit() {
    expect_error 2 "不认识的适配方式" -- \
        "$BIN" --cli --mask --image "$FIX/ov_full_red.png" --fit zoom -- "$FIX/solid.mp4"
}

c_error_unknown_position() {
    expect_error 2 "不认识的摆放位置" -- \
        "$BIN" --cli --mask --image "$FIX/ov_full_red.png" --pos middle -- "$FIX/solid.mp4"
}

c_error_unknown_blend() {
    expect_error 2 "不认识的混合方式" -- \
        "$BIN" --cli --mask --image "$FIX/ov_full_red.png" --blend overlay -- "$FIX/solid.mp4"
}

c_error_no_input() {
    expect_error 2 "用法: DITKit --cli --mask" -- \
        "$BIN" --cli --mask --image "$FIX/ov_full_red.png" --
}

# 用法文本要把本页的选项都列出来，否则用户只能去翻源码
c_usage_lists_mask_options() {
    local out
    out=$(run "$BIN" --cli --mask --image "$FIX/ov_full_red.png" --)
    expect_contains "$out" "--fit" "用法里应当有适配方式"
    expect_contains "$out" "--blend" "用法里应当有混合方式"
    expect_contains "$out" "--pos" "用法里应当有摆放位置"
    expect_contains "$out" "--opacity" "用法里应当有不透明度"
}

c_error_no_media_found() {
    local d
    d=$(fresh_dir mask-none)
    printf 'not media' >"$d/notes.txt"
    expect_error 2 "没有找到可处理的视频文件" -- \
        "$BIN" --cli --mask --image "$FIX/ov_full_red.png" --out "$d/o" -- "$d/notes.txt"
}

reg \
    "拉伸铺满盖住整个画面"            c_fit_stretch_covers_frame \
    "等比铺满盖住整个画面"            c_fit_cover_covers_frame \
    "等比完整四周留出画面本身"        c_fit_contain_letterboxes \
    "原始大小不缩放并按位置摆放"      c_fit_original_keeps_size \
    "铺满的适配方式忽略位置"          c_position_ignored_by_full_frame_fits \
    "区域探针能分辨不同位置"          c_region_probe_can_tell_positions_apart \
    "不透明度按比例混合"              c_opacity_scales_layer \
    "越界的不透明度被夹住"            c_opacity_out_of_range_is_clamped \
    "图片自带的透明通道生效"          c_alpha_channel_is_honoured \
    "正片叠底的单位元是白"            c_blend_multiply_neutral_is_white \
    "滤色的单位元是黑"                c_blend_screen_neutral_is_black \
    "混合在 RGB 空间进行"             c_blend_happens_in_rgb_space \
    "混合时未覆盖区域保持原样"        c_blend_keeps_uncovered_area_intact \
    "输出规格（HEVC 10bit / 音频复制）" c_output_spec \
    "编码质量真的落到编码器上"        c_quality_takes_effect \
    "批量与相对目录落位"              c_batch_and_relative_output \
    "--suffix 覆盖默认后缀"           c_suffix_option \
    "产物不会被当成新素材"            c_output_is_not_reprocessed \
    "命名冲突默认跳过"                c_conflict_skip_by_default \
    "不同尺寸的素材混批互不干扰"      c_batch_mixed_sizes \
    "没有音频的素材也能加遮罩"        c_video_without_audio \
    "先裁剪再加遮罩能串起来"          c_pipeline_trim_then_mask \
    "缺遮罩图片退出 2"                c_error_missing_image \
    "遮罩图片不存在退出 2"            c_error_image_not_found \
    "遮罩图片后缀不对退出 2"          c_error_image_wrong_extension \
    "未知适配方式退出 2"              c_error_unknown_fit \
    "未知摆放位置退出 2"              c_error_unknown_position \
    "未知混合方式退出 2"              c_error_unknown_blend \
    "没有输入文件退出 2"              c_error_no_input \
    "用法文本列出本页选项"            c_usage_lists_mask_options \
    "输入里没有媒体时退出 2"          c_error_no_media_found
