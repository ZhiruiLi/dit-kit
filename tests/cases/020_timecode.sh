#!/usr/bin/env bash
# 时间码解析。用一个足够大的 --end 绕开「终点必须大于起点」的校验，
# 只观察解析结果 —— 程序会把解析出来的范围打在「范围  : 起 → 止」这一行。
GROUP="时间码"

SCRATCH=""

setup_scratch() {
    [ -n "$SCRATCH" ] && return 0
    SCRATCH="$WORK/out/timecode"
    mkdir -p "$SCRATCH"
}

# 断言某个写法解析出来的起点
expect_start_eq() {
    local input="$1" want="$2"
    setup_scratch
    local got
    got=$(run "$BIN" --cli --trim --start "$input" --end 5000 --fast \
        --out "$SCRATCH" -- "$FIX/ruler_a.mp4" |
        sed -n 's/^范围  : \([^→]*\).*/\1/p' | tr -d ' ')
    expect_eq "$want" "$got" "「${input}」解析出的起点"
}

c_plain_seconds() { expect_start_eq 2 00:00:02.000; }
c_mmss() { expect_start_eq 01:30 00:01:30.000; }
c_hhmmss() { expect_start_eq 00:01:30 00:01:30.000; }
c_millis() { expect_start_eq 00:01:30.500 00:01:30.500; }
c_suffix_s() { expect_start_eq 5s 00:00:05.000; }
c_suffix_fraction() { expect_start_eq 0.5s 00:00:00.500; }
c_suffix_m() { expect_start_eq 2m 00:02:00.000; }
c_suffix_combo() { expect_start_eq 1m30s 00:01:30.000; }
c_suffix_h() { expect_start_eq 1h 01:00:00.000; }
c_suffix_hms() { expect_start_eq 1h2m3s 01:02:03.000; }

# 六种写法必须落到同一个点上
c_equivalent_forms() {
    local ref="" got form
    for form in 90 1m30s 01:30 00:01:30 00:01:30.000 1m30.000s; do
        setup_scratch
        got=$(run "$BIN" --cli --trim --start "$form" --end 5000 --fast \
            --out "$SCRATCH" -- "$FIX/ruler_a.mp4" |
            sed -n 's/^范围  : \([^→]*\).*/\1/p' | tr -d ' ')
        [ -n "$ref" ] || ref="$got"
        expect_eq "$ref" "$got" "「${form}」应与「90」等价"
    done
    expect_eq "00:01:30.000" "$ref" "参考值"
}

# 片段长度也要跟着算对（只从「范围」这一行取，否则会误取到「方式」行的括号）
c_duration_math() {
    setup_scratch
    local got
    got=$(run "$BIN" --cli --trim --start 00:00:02.500 --end 00:00:05.000 --fast \
        --out "$SCRATCH" -- "$FIX/ruler_a.mp4" |
        sed -n 's/^范围  : .*（\(.*\)）.*$/\1/p' | tr -d ' ')
    expect_eq "00:00:02.500" "$got" "范围长度"
}

c_reject_letters() {
    expect_error 2 "起点时间格式看不懂" -- \
        "$BIN" --cli --trim --start abc --end 5 -- "$FIX/ruler_a.mp4"
}

c_reject_four_parts() {
    expect_error 2 "起点时间格式看不懂" -- \
        "$BIN" --cli --trim --start 1:2:3:4 --end 5 -- "$FIX/ruler_a.mp4"
}

c_reject_empty() {
    expect_error 2 "起点时间格式看不懂" -- \
        "$BIN" --cli --trim --start "" --end 5 -- "$FIX/ruler_a.mp4"
}

reg \
    "纯秒数 2"                c_plain_seconds \
    "分:秒 01:30"             c_mmss \
    "时:分:秒 00:01:30"       c_hhmmss \
    "带毫秒 00:01:30.500"     c_millis \
    "单位后缀 5s"             c_suffix_s \
    "小数 0.5s"               c_suffix_fraction \
    "单位后缀 2m"             c_suffix_m \
    "组合 1m30s"              c_suffix_combo \
    "组合 1h"                 c_suffix_h \
    "组合 1h2m3s"             c_suffix_hms \
    "六种写法解析结果一致"    c_equivalent_forms \
    "范围长度计算正确"        c_duration_math \
    "字母被拒"                c_reject_letters \
    "四段冒号被拒"            c_reject_four_parts \
    "空字符串被拒"            c_reject_empty
