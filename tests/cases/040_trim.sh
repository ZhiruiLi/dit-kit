#!/usr/bin/env bash
# 裁剪：起点精度、时长、两种模式各自的语义、输出布局、批量。
#
# 素材是「时间码标尺」——每 0.5 秒一种颜色（10 色循环）。
# 取输出第 0.25 秒的一帧，它在源里对应「起点 + 0.25」秒，
# 应当是那一段的中间位置，于是可以反过来精确断言起点有没有取对。
# 探针刻意取段中点，离两边的色块边界都还有 0.25 秒余量。
GROUP="裁剪"
PROBE_AT=0.25

# 断言「精确重编码」的起点准确：输出 PROBE_AT 处的颜色 == 源 (起点+PROBE_AT) 处的段
expect_exact_start() {
    local start="$1" end="$2" tag="$3"
    local d src_t want got
    d=$(fresh_dir "trim-acc-$tag")
    run "$BIN" --cli --trim --start "$start" --end "$end" --exact --out "$d" -- "$FIX/ruler_a.mp4" >/dev/null
    expect_file "$d/ruler_a_trim.mp4"
    src_t=$(awk -v s="$start" -v p="$PROBE_AT" 'BEGIN { printf "%.3f", s + p }')
    want=$(ruler_expected "$src_t")
    got=$(ruler_second "$d/ruler_a_trim.mp4" "$PROBE_AT")
    expect_eq "$want" "$got" "起点 $start 的片段（输出 ${PROBE_AT}s 对应源 ${src_t}s）颜色段"
}

c_exact_start_on_keyframe() { expect_exact_start 2 3.5 kf; }
c_exact_start_off_keyframe() { expect_exact_start 3.5 5 offkf; }
c_exact_start_late() { expect_exact_start 6 7 late; }

# 另一个起点也验证一遍，避免恰好只对一个位置成立
c_exact_start_spot_check() {
    local d src_t want got
    d=$(fresh_dir trim-spot)
    run "$BIN" --cli --trim --start 4.5 --end 6 --exact --out "$d" -- "$FIX/ruler_a.mp4" >/dev/null
    src_t=$(awk 'BEGIN { printf "%.3f", 4.5 + 0.25 }')
    want=$(ruler_expected "$src_t")
    got=$(ruler_second "$d/ruler_a_trim.mp4" 0.25)
    expect_eq "$want" "$got" "起点 4.5 处颜色段"
}

c_exact_duration_and_codec() {
    local d
    d=$(fresh_dir trim-exact)
    run "$BIN" --cli --trim --start 2 --end 5 --exact --out "$d" -- "$FIX/ruler_a.mp4" >/dev/null
    expect_near 3.0 "$(probe_duration "$d/ruler_a_trim.mp4")" 0.15 "精确模式输出时长"
    expect_eq "hevc" "$(probe_vcodec "$d/ruler_a_trim.mp4")" "视频编码"
    expect_eq "yuv420p10le" "$(probe_pixfmt "$d/ruler_a_trim.mp4")" "像素格式（10bit）"
}

# 流复制：不重编码（源是 h264，输出应当还是 h264），起点落在关键帧上，
# 且因为会回退到关键帧，产物不会比请求的片段短。
c_fast_stream_copy() {
    local d dur
    d=$(fresh_dir trim-fast)
    run "$BIN" --cli --trim --start 3 --end 5 --fast --out "$d" -- "$FIX/ruler_a.mp4" >/dev/null
    expect_file "$d/ruler_a_trim.mp4"
    expect_eq "h264" "$(probe_vcodec "$d/ruler_a_trim.mp4")" "流复制应保留源编码"
    expect_contains "$(probe_first_packet_flags "$d/ruler_a_trim.mp4")" "K" "首个视频包应当是关键帧"
    dur=$(probe_duration "$d/ruler_a_trim.mp4")
    expect_ge "$dur" 2.0 "流复制产物不会短于请求片段"
    note "流复制时长=${dur}（请求 2.0s）"
}

# 起点正好落在关键帧上时，流复制的内容应当与请求完全一致
c_fast_start_on_keyframe() {
    local d want got
    d=$(fresh_dir trim-fast-kf)
    run "$BIN" --cli --trim --start 3 --end 5 --fast --out "$d" -- "$FIX/ruler_a.mp4" >/dev/null
    want=$(ruler_expected 3.25)
    got=$(ruler_second "$d/ruler_a_trim.mp4" 0.25)
    expect_eq "$want" "$got" "关键帧对齐时流复制的起始颜色段"
}

c_suffix_option() {
    local d out
    d=$(fresh_dir trim-suffix)
    out=$(run "$BIN" --cli --trim --start 2 --end 3 --fast --out "$d" --suffix _cut -- "$FIX/ruler_a.mp4")
    expect_contains "$out" "结束：共 1，失败 0" "运行结果"
    expect_file "$d/ruler_a_cut.mp4"
    expect_no_file "$d/ruler_a_trim.mp4"
}

c_relative_output() {
    local d out
    d=$(fresh_dir trim-relative)
    mkdir -p "$d/in/子目录"
    cp "$FIX/ruler_a.mp4" "$d/in/顶层.mp4"
    cp "$FIX/ruler_b.mp4" "$d/in/子目录/嵌套.mp4"
    out=$(run "$BIN" --cli --trim --start 1 --end 2 --fast --relative 切片 -- "$d/in")
    expect_contains "$out" "结束：共 2，失败 0" "相对输出结果"
    expect_file "$d/in/切片/顶层_trim.mp4"
    expect_file "$d/in/子目录/切片/嵌套_trim.mp4"
}

c_batch_two_clips() {
    local d out
    d=$(fresh_dir trim-batch)
    out=$(run "$BIN" --cli --trim --start 1 --end 3 --exact --out "$d" --jobs 2 -- \
        "$FIX/ruler_a.mp4" "$FIX/ruler_b.mp4")
    expect_contains "$out" "结束：共 2，失败 0" "批量结果"
    expect_file "$d/ruler_a_trim.mp4"
    expect_file "$d/ruler_b_trim.mp4"
}

# 两页可以串起来用：先套 LUT，再对产物做裁剪
c_pipeline_lut_then_trim() {
    local d want got
    d=$(fresh_dir trim-pipeline)
    run "$BIN" --cli --lut "$FIX/swap.cube" --out "$d/lut" -- "$FIX/solid.mp4" >/dev/null
    expect_file "$d/lut/solid_graded.mp4"
    run "$BIN" --cli --trim --end 1 --fast --out "$d/cut" -- "$d/lut/solid_graded.mp4" >/dev/null
    expect_file "$d/cut/solid_graded_trim.mp4"
    # 换过通道的颜色应当一路保留下来
    want=$(read_rgb "$FIX/solid.tsv" | awk '{print $3, $2, $1}')
    got=$(frame_rgb "$d/cut/solid_graded_trim.mp4" 0.5)
    expect_rgb_near "$want" "$got" 8 "LUT 后再裁剪的颜色"
}

# 超范围不应当崩、也不应当卡住
c_range_beyond_source_does_not_crash() {
    local d rc
    d=$(fresh_dir trim-beyond)
    rc=$(exit_code "$BIN" --cli --trim --start 60 --end 90 --fast --out "$d" -- "$FIX/ruler_a.mp4")
    case "$rc" in
        0 | 1) ;;
        *) fail "超范围时退出码异常: ${rc}（应当是 0 或 1）" ;;
    esac
    note "超出源时长时退出码=${rc}"
}

# 终点超出源尾时应当裁到源尾为止，而不是报错或产出超长文件
c_end_clamped_to_source_tail() {
    local d dur
    d=$(fresh_dir trim-clamp)
    run "$BIN" --cli --trim --start 8 --end 20 --fast --out "$d" -- "$FIX/ruler_a.mp4" >/dev/null
    expect_file "$d/ruler_a_trim.mp4"
    dur=$(probe_duration "$d/ruler_a_trim.mp4")
    expect_le "$dur" 10.1 "产物不应超过源时长"
    expect_ge "$dur" 1.5 "应当覆盖请求范围内源里确实存在的部分"
    note "源 10s，请求 8→20，产物 ${dur}s"
}

# 已知问题 —— 这条锁定的是「当前行为」，不是期望行为。
# 起止完全落在源之外时，ffmpeg 留下一个没有有效媒体的空容器（约 257 字节），
# 而程序照样报告「[完成] … 失败 0」。
# 一旦有人把「空产物算失败」修好，这条会变红，提醒把断言反过来。
c_known_issue_out_of_range_reported_done() {
    local d out size
    d=$(fresh_dir trim-beyond-exact)
    out=$(run "$BIN" --cli --trim --start 60 --end 90 --exact --out "$d" -- "$FIX/ruler_a.mp4")
    expect_contains "$out" "失败 0" "当前行为：超范围仍报告成功"
    expect_file "$d/ruler_a_trim.mp4"
    size=$(stat -f %z "$d/ruler_a_trim.mp4")
    expect_le "$size" 4096 "当前行为：产物是个空容器"
    note "产物 ${size} 字节、没有有效媒体，却被报成完成 —— 已知问题，见 README"
}

reg \
    "精确模式起点准确（关键帧上）"      c_exact_start_on_keyframe \
    "精确模式起点准确（非关键帧）"      c_exact_start_off_keyframe \
    "精确模式起点准确（靠后位置）"      c_exact_start_late \
    "精确模式起点准确（抽查 4.5s）"     c_exact_start_spot_check \
    "精确模式时长与编码"                c_exact_duration_and_codec \
    "流复制保持源编码并从关键帧起"      c_fast_stream_copy \
    "流复制起点落在关键帧上时内容正确"  c_fast_start_on_keyframe \
    "--suffix 覆盖默认后缀"             c_suffix_option \
    "--relative 落到源目录子目录"       c_relative_output \
    "两个文件一起批量裁剪"              c_batch_two_clips \
    "先套 LUT 再裁剪能串起来"           c_pipeline_lut_then_trim \
    "范围超出源时长不崩"                c_range_beyond_source_does_not_crash \
    "终点超出源尾时裁到源尾"            c_end_clamped_to_source_tail \
    "已知问题：空产物被报成完成"        c_known_issue_out_of_range_reported_done
