#!/usr/bin/env bash
# 命令行接口：用法文本、退出码、各种错误路径的提示。
# 退出码约定（源码里是 `return failed == 0 ? 0 : 1;`）：
#   0 全部成功 / 1 有任务失败或前置校验不通过 / 2 参数与用法错误
GROUP="命令行"

c_help_exit0() {
    local out
    out=$(run "$BIN" --help)
    expect_contains "$out" "LUT 模式" "帮助文本"
    expect_contains "$out" "裁剪模式" "帮助文本"
    expect_contains "$out" "音频提取模式" "帮助文本"
    expect_contains "$out" "图片遮罩模式" "帮助文本"
    expect_contains "$out" "--conflict" "帮助文本"
    expect_eq "0" "$(exit_code "$BIN" --help)" "help 退出码"
}

c_no_mode() {
    expect_error 2 "DITKit —— 视频工具箱" -- "$BIN" --cli
}

c_lut_missing_value() {
    expect_error 2 "用法: DITKit --cli --lut" -- "$BIN" --cli --lut
}

c_lut_missing_file() {
    expect_error 1 "LUT 文件不存在" -- \
        "$BIN" --cli --lut "$WORK/这个文件不存在.cube" -- "$FIX/ruler_a.mp4"
}

c_trim_missing_end() {
    expect_error 2 "用法: DITKit --cli --trim" -- "$BIN" --cli --trim -- "$FIX/ruler_a.mp4"
}

c_trim_bad_time() {
    expect_error 2 "时间格式看不懂" -- \
        "$BIN" --cli --trim --end 不是时间 -- "$FIX/ruler_a.mp4"
}

c_trim_reversed_range() {
    expect_error 2 "终点必须大于起点" -- \
        "$BIN" --cli --trim --start 5 --end 3 -- "$FIX/ruler_a.mp4"
}

c_trim_no_input() {
    expect_error 2 "用法: DITKit --cli --trim" -- "$BIN" --cli --trim --end 5 --
}

c_unknown_flag() {
    expect_error 2 "DITKit —— 视频工具箱" -- "$BIN" --cli --bogus
}

c_no_media_found() {
    local d
    d=$(fresh_dir cli-none)
    printf 'not a video' >"$d/notes.txt"
    expect_error 2 "没有找到可处理的视频文件" -- \
        "$BIN" --cli --lut "$FIX/identity.cube" --out "$d" -- "$d/notes.txt"
}

reg \
    "help 列出两种模式且退出码 0"        c_help_exit0 \
    "--cli 不带模式退出 2"               c_no_mode \
    "--lut 缺参数值退出 2"               c_lut_missing_value \
    "LUT 文件不存在时退出 1"             c_lut_missing_file \
    "--trim 缺 --end 退出 2"             c_trim_missing_end \
    "时间码非法退出 2 并说明原因"        c_trim_bad_time \
    "终点不大于起点退出 2"               c_trim_reversed_range \
    "没有输入文件退出 2"                 c_trim_no_input \
    "未知参数退出 2"                     c_unknown_flag \
    "输入里没有视频时退出 2 并提示"      c_no_media_found
