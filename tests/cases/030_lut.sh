#!/usr/bin/env bash
# LUT 批量套用：编码规格、LUT 是否真的起作用、批量、输出布局、冲突策略、产物排除。
GROUP="LUT"

SOLID_IN="128 64 32"   # 素材 solid.mp4 的颜色，见 tests/work/fixtures/solid.tsv

c_single_encode() {
    local d
    d=$(fresh_dir lut-single)
    local out
    out=$(run "$BIN" --cli --lut "$FIX/identity.cube" --out "$d" -- "$FIX/solid.mp4")
    expect_contains "$out" "结束：共 1，失败 0" "转换结果"
    expect_file "$d/solid_graded.mp4"
    expect_eq "hevc" "$(probe_vcodec "$d/solid_graded.mp4")" "视频编码"
    expect_eq "yuv420p10le" "$(probe_pixfmt "$d/solid_graded.mp4")" "像素格式（10bit 防断层）"
}

# 恒等 LUT：颜色不该被改动。这条是下一条的对照 —— 说明管线本身不偏色。
c_identity_lut_keeps_color() {
    local d src got
    d=$(fresh_dir lut-identity)
    run "$BIN" --cli --lut "$FIX/identity.cube" --out "$d" -- "$FIX/solid.mp4" >/dev/null
    expect_file "$d/solid_graded.mp4"
    src=$(frame_rgb "$FIX/solid.mp4" 1.0)
    got=$(frame_rgb "$d/solid_graded.mp4" 1.0)
    expect_rgb_near "$src" "$got" 6 "恒等 LUT 输出颜色"
    note "源=[$src] 输出=[$got]"
}

# R↔B 互换 LUT：输入 (R,G,B) 必须得到 (B,G,R)。
# 这个映射是线性的，2 点 cube 的三线性插值能精确复现，所以是一条硬断言 ——
# 它同时证明了「LUT 被套用了」和「套用方向是对的」，比只看颜色变了没强得多。
c_swap_lut_swaps_channels() {
    local d src got want
    d=$(fresh_dir lut-swap)
    run "$BIN" --cli --lut "$FIX/swap.cube" --out "$d" -- "$FIX/solid.mp4" >/dev/null
    expect_file "$d/solid_graded.mp4"
    src=$(frame_rgb "$FIX/solid.mp4" 1.0)
    got=$(frame_rgb "$d/solid_graded.mp4" 1.0)
    # 期望值直接由实测的源颜色推出，不写死常数
    want=$(printf '%s' "$src" | awk '{print $3, $2, $1}')
    expect_rgb_near "$want" "$got" 6 "交换 LUT 输出颜色"
    expect_ne "$src" "$got" "交换 LUT 输出应当与源不同"
    note "源=[$src] 期望=[$want] 输出=[$got]"
}

# 规格差异很大的两个文件一起批量，互不干扰
c_batch_two_clips() {
    local d out
    d=$(fresh_dir lut-batch)
    out=$(run "$BIN" --cli --lut "$FIX/identity.cube" --out "$d" --jobs 2 -- \
        "$FIX/ruler_a.mp4" "$FIX/ruler_b.mp4")
    expect_contains "$out" "结束：共 2，失败 0" "批量结果"
    expect_file "$d/ruler_a_graded.mp4"
    expect_file "$d/ruler_b_graded.mp4"
    expect_ne "$(probe_pixfmt "$d/ruler_a_graded.mp4")" "" "A 输出可解析"
    expect_ne "$(probe_pixfmt "$d/ruler_b_graded.mp4")" "" "B 输出可解析"
}

# 传目录时应当递归收进子目录里的视频
c_directory_is_recursive() {
    local d out
    d=$(fresh_dir lut-dir)
    mkdir -p "$d/in/子目录"
    cp "$FIX/ruler_a.mp4" "$d/in/顶层.mp4"
    cp "$FIX/ruler_b.mp4" "$d/in/子目录/嵌套.mp4"
    out=$(run "$BIN" --cli --lut "$FIX/identity.cube" --out "$d/out" -- "$d/in")
    expect_contains "$out" "结束：共 2，失败 0" "目录递归结果"
    expect_file "$d/out/顶层_graded.mp4"
    expect_file "$d/out/嵌套_graded.mp4"
}

# --relative：产物落到每个源文件所在目录的子目录里
c_relative_output() {
    local d out
    d=$(fresh_dir lut-relative)
    mkdir -p "$d/in/子目录"
    cp "$FIX/ruler_a.mp4" "$d/in/顶层.mp4"
    cp "$FIX/ruler_b.mp4" "$d/in/子目录/嵌套.mp4"
    out=$(run "$BIN" --cli --lut "$FIX/identity.cube" --relative graded -- "$d/in")
    expect_contains "$out" "结束：共 2，失败 0" "相对输出结果"
    expect_file "$d/in/graded/顶层_graded.mp4"
    expect_file "$d/in/子目录/graded/嵌套_graded.mp4"
}

# 冲突策略 skip：第二次跑不该重做，应当报告跳过
c_conflict_skip() {
    local d out
    d=$(fresh_dir lut-skip)
    run "$BIN" --cli --lut "$FIX/identity.cube" --out "$d" -- "$FIX/ruler_a.mp4" >/dev/null
    out=$(run "$BIN" --cli --lut "$FIX/identity.cube" --out "$d" --conflict skip -- "$FIX/ruler_a.mp4")
    expect_contains "$out" "[跳过]" "第二次运行"
    expect_contains "$out" "失败 0" "跳过不算失败"
}

c_conflict_rename() {
    local d out
    d=$(fresh_dir lut-rename)
    run "$BIN" --cli --lut "$FIX/identity.cube" --out "$d" -- "$FIX/ruler_a.mp4" >/dev/null
    out=$(run "$BIN" --cli --lut "$FIX/identity.cube" --out "$d" --conflict rename -- "$FIX/ruler_a.mp4")
    expect_contains "$out" "_graded (1).mp4" "重命名产物"
    expect_file "$d/ruler_a_graded.mp4"
    expect_file "$d/ruler_a_graded (1).mp4"
}

c_conflict_overwrite() {
    local d out before after
    d=$(fresh_dir lut-overwrite)
    run "$BIN" --cli --lut "$FIX/identity.cube" --out "$d" -- "$FIX/ruler_a.mp4" >/dev/null
    before=$(stat -f %m "$d/ruler_a_graded.mp4")
    sleep 1
    out=$(run "$BIN" --cli --lut "$FIX/identity.cube" --out "$d" --conflict overwrite -- "$FIX/ruler_a.mp4")
    expect_contains "$out" "[完成]" "覆盖运行"
    expect_no_file "$d/ruler_a_graded (1).mp4"
    after=$(stat -f %m "$d/ruler_a_graded.mp4")
    expect_ne "$before" "$after" "覆盖后文件应被重写"
}

# 产物排除：已经带输出后缀的文件不该被当成新素材。
# 「重命名」策略产生的 `xxx_graded (1).mp4` 也要能识别 —— 这里守的是一个真实修过的 bug：
# 只认 `_graded` 结尾时，这类文件会在下次扫描时被重新处理一遍。
c_generated_files_excluded() {
    local d out
    d=$(fresh_dir lut-exclude)
    cp "$FIX/ruler_a.mp4" "$d/素材.mp4"
    cp "$FIX/ruler_a.mp4" "$d/素材_graded.mp4"
    cp "$FIX/ruler_a.mp4" "$d/素材_graded (1).mp4"
    out=$(run "$BIN" --cli --lut "$FIX/identity.cube" --out "$d/out" -- "$d")
    expect_contains "$out" "文件数: 1" "只应把 1 个文件当输入"
    expect_contains "$out" "结束：共 1，失败 0" "运行结果"
    expect_file "$d/out/素材_graded.mp4"
}

# --suffix 可覆盖默认后缀
c_custom_suffix() {
    local d out
    d=$(fresh_dir lut-suffix)
    out=$(run "$BIN" --cli --lut "$FIX/identity.cube" --out "$d" --suffix _look -- "$FIX/ruler_a.mp4")
    expect_contains "$out" "结束：共 1，失败 0" "运行结果"
    expect_file "$d/ruler_a_look.mp4"
    expect_no_file "$d/ruler_a_graded.mp4"
}

# 隐藏文件与隐藏目录不作为输入（.DS_Store、.git 之类不该被处理）
c_hidden_paths_excluded() {
    local d out
    d=$(fresh_dir lut-hidden)
    mkdir -p "$d/in/.隐藏目录"
    cp "$FIX/ruler_a.mp4" "$d/in/正常.mp4"
    cp "$FIX/ruler_b.mp4" "$d/in/.隐藏.mp4"
    cp "$FIX/ruler_b.mp4" "$d/in/.隐藏目录/里面.mp4"
    out=$(run "$BIN" --cli --lut "$FIX/identity.cube" --out "$d/out" -- "$d/in")
    expect_contains "$out" "文件数: 1" "只应处理可见文件"
    expect_file "$d/out/正常_graded.mp4"
}

reg \
    "单文件转换的编码规格"          c_single_encode \
    "恒等 LUT 不改颜色"             c_identity_lut_keeps_color \
    "交换 LUT 精确交换 R/B 通道"    c_swap_lut_swaps_channels \
    "两个不同规格文件一起批量"      c_batch_two_clips \
    "传目录会递归进子目录"          c_directory_is_recursive \
    "--relative 落到源目录子目录"   c_relative_output \
    "冲突策略 skip"                 c_conflict_skip \
    "冲突策略 rename"               c_conflict_rename \
    "冲突策略 overwrite"            c_conflict_overwrite \
    "产物不被当新素材重复处理"      c_generated_files_excluded \
    "--suffix 覆盖默认后缀"         c_custom_suffix \
    "隐藏文件与隐藏目录不处理"      c_hidden_paths_excluded
