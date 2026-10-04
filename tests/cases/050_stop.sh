#!/usr/bin/env bash
# 引擎收尾：转换中点击停止，以及不停止一次跑完。
#
# 停止用例刻意构造「1 个在跑、N 个排队」：并发 1 + N 个文件。
# 这正是「点停止后永久卡在正在停止…」那个 bug 的触发条件 ——
# cancel 若只杀活跃任务而漏记排队任务，收尾条件 (_active==0 && _queue==0)
# 就永远不成立，onFinished 不触发，界面永久停在「正在停止…」。
# 所以这里断言的不是「有没有停下来」，而是「排队任务有没有被正确记账」。
GROUP="引擎收尾"

STOP_N=8

# N 份素材。用硬链接指向同一个文件：内容相同、耗时相同，但不占额外磁盘，
# 而且路径各不相同（引擎会按路径去重，同一路径重复投喂只会算一个任务）。
build_inputs() {
    local d="$1" i
    mkdir -p "$d"
    i=1
    while [ "$i" -le "$STOP_N" ]; do
        if [ ! -f "$d/f$i.mp4" ]; then
            ln "$FIX/long.mp4" "$d/f$i.mp4" 2>/dev/null || cp "$FIX/long.mp4" "$d/f$i.mp4"
        fi
        i=$((i + 1))
    done
}

drop_list() {
    local d="$1" list="" i
    i=1
    while [ "$i" -le "$STOP_N" ]; do
        list="${list}|$d/f$i.mp4"
        i=$((i + 1))
    done
    printf '%s' "${list#|}"
}

# LUT 页：1.5 秒时点停止。此时 1 个任务在跑、7 个在排队。
c_lut_stop_drains_queue() {
    gui_available || skip "当前会话没有图形界面"
    local d out log status n
    d="$WORK/stop/lut"
    rm -rf "$d"
    build_inputs "$d/in"
    mkdir -p "$d/out"

    defaults_reset
    defaults_set_int lut.concurrency 1
    defaults_set_int lut.outMode 1
    defaults_set_str lut.outValue "$d/out"
    defaults_set_int lut.conflict 2 # rename，避免上一轮残留干扰

    log=$(gui_run 60 "$WORK/stop/lut.log" \
        DITKIT_APPEARANCE=dark DITKIT_PAGE=0 DITKIT_AUTOSTART=1 \
        DITKIT_STOP_AFTER=1.5 DITKIT_EXIT_WHEN_IDLE=1 DITKIT_TIMEOUT=45 \
        DITKIT_LUT="$FIX/identity.cube" DITKIT_DROP="$(drop_list "$d/in")")
    gui_ran "$log" || skip "自检没能启动"

    expect_eq "0" "$(gui_busy "$log")" "停止后引擎必须收尾（busy 要回到 0）"
    status=$(gui_status "$log")
    expect_contains "$status" "已停止" "状态行"
    expect_contains "$status" "已取消 $STOP_N" "排队任务也要被记账为已取消"
    note "状态行: $status"

    # 排队任务一个都不该被处理
    n=$(ls "$d/out" 2>/dev/null | wc -l | tr -d ' ')
    expect_le "$n" 1 "停止后至多只有 1 个产物（其余都在排队）"
    expect_eq "0" "$(leftover_ffmpeg "$d/out")" "不应残留 ffmpeg 进程"
}

# 裁剪页同一套收尾路径
c_trim_stop_drains_queue() {
    gui_available || skip "当前会话没有图形界面"
    local d log status
    d="$WORK/stop/trim"
    rm -rf "$d"
    build_inputs "$d/in"
    mkdir -p "$d/out"

    defaults_reset
    defaults_set_int trim.concurrency 1
    defaults_set_int trim.outMode 1
    defaults_set_str trim.outValue "$d/out"
    defaults_set_int trim.conflict 2
    defaults_set_bool trim.fastCopy false # 精确重编码，任务才有时长可被打断

    log=$(gui_run 60 "$WORK/stop/trim.log" \
        DITKIT_APPEARANCE=dark DITKIT_PAGE=1 DITKIT_AUTOSTART=1 \
        DITKIT_STOP_AFTER=1.5 DITKIT_EXIT_WHEN_IDLE=1 DITKIT_TIMEOUT=45 \
        DITKIT_TRIM_START=00:00:02 DITKIT_TRIM_END=00:00:18 \
        DITKIT_DROP="$(drop_list "$d/in")")
    gui_ran "$log" || skip "自检没能启动"

    expect_eq "0" "$(gui_busy "$log")" "停止后引擎必须收尾"
    status=$(gui_status "$log")
    expect_contains "$status" "已停止" "状态行"
    expect_contains "$status" "已取消 $STOP_N" "排队任务也要被记账为已取消"
    note "状态行: $status"
}

# 不点停止：应当正常跑完，且排队任务全部完成。
# 这条是上一条的对照 —— 防止「停止能收尾」是靠「干脆什么都不做」实现的。
c_lut_full_run() {
    gui_available || skip "当前会话没有图形界面"
    local d log status n
    d="$WORK/stop/full"
    rm -rf "$d"
    mkdir -p "$d/in" "$d/out"
    ln "$FIX/long.mp4" "$d/in/f1.mp4" 2>/dev/null || cp "$FIX/long.mp4" "$d/in/f1.mp4"
    ln "$FIX/long.mp4" "$d/in/f2.mp4" 2>/dev/null || cp "$FIX/long.mp4" "$d/in/f2.mp4"
    ln "$FIX/long.mp4" "$d/in/f3.mp4" 2>/dev/null || cp "$FIX/long.mp4" "$d/in/f3.mp4"
    ln "$FIX/long.mp4" "$d/in/f4.mp4" 2>/dev/null || cp "$FIX/long.mp4" "$d/in/f4.mp4"

    defaults_reset
    defaults_set_int lut.concurrency 4
    defaults_set_int lut.outMode 1
    defaults_set_str lut.outValue "$d/out"
    defaults_set_int lut.conflict 2

    log=$(gui_run 120 "$WORK/stop/full.log" \
        DITKIT_APPEARANCE=dark DITKIT_PAGE=0 DITKIT_AUTOSTART=1 \
        DITKIT_EXIT_WHEN_IDLE=1 DITKIT_TIMEOUT=110 \
        DITKIT_LUT="$FIX/identity.cube" \
        DITKIT_DROP="$d/in/f1.mp4|$d/in/f2.mp4|$d/in/f3.mp4|$d/in/f4.mp4")
    gui_ran "$log" || skip "自检没能启动"

    expect_eq "0" "$(gui_busy "$log")" "跑完后应当空闲"
    status=$(gui_status "$log")
    expect_contains "$status" "成功 4" "汇总应当报告 4 个成功"
    n=$(ls "$d/out" 2>/dev/null | wc -l | tr -d ' ')
    expect_eq "4" "$n" "产物数量"
    note "状态行: $status"
}

# 提示：停止时被杀掉的任务会在磁盘留下一个「可播放的残片」
# （ffmpeg 收到 SIGTERM 会优雅收尾、把容器写完）。
# 这里只把它报出来，不做好坏判断 —— 处理方式还没定。
c_stop_partial_note() {
    local d n
    d="$WORK/stop/lut/out"
    [ -d "$d" ] || skip "上一轮停止用例没跑，跳过"
    n=$(ls "$d" 2>/dev/null | wc -l | tr -d ' ')
    expect_le "$n" 1 "停止后产物数量"
    note "停止时产物目录里有 $n 个文件（被杀任务留下的残片是完整可播放的，见 README 已知限制）"
}

reg \
    "LUT 页停止后排队的任务被正确记账"        c_lut_stop_drains_queue \
    "裁剪页停止后排队的任务被正确记账"        c_trim_stop_drains_queue \
    "不停止时全部跑完"                        c_lut_full_run \
    "停止后至多留下 1 个产物"                 c_stop_partial_note
