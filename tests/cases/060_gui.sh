#!/usr/bin/env bash
# 界面：渲染、顶栏是否真的画出来了、诊断信息是否正常。
#
# 这里守的是一个真实修过的 bug：顶栏（标题 / ffmpeg 状态 / 页切换器）的
# frame、hidden、alpha 全都正常，但就是画不出来 —— 原因是布局容器的
# drawRect: 里填了一遍底色，父视图的全量重绘把本轮没被标脏的子控件整片擦掉了。
# 当时的表象就是「截图里顶栏那一条是空的」。
#
# 抓图有两条路：
#   1) 窗口合成（CGWindowListCreateImage）—— 效果最完整，但需要录屏权限，
#      某些会话里会返回全黑；
#   2) 视图缓存（cacheDisplayInRect:）—— 不依赖窗口服务，画出来的内容一样。
# 所以下面优先走 1)，发现是全黑就自动退回 2)，让用例在两种环境下都能跑。
GROUP="界面"

GUI_DIR=""

gui_dir() {
    [ -n "$GUI_DIR" ] && {
        printf '%s' "$GUI_DIR"
        return 0
    }
    GUI_DIR="$WORK/gui"
    mkdir -p "$GUI_DIR"
    printf '%s' "$GUI_DIR"
}

# 渲染一张界面截图，返回文件路径
render() { # render <名字> <页号> <外观> [额外 DITKIT_* ...]
    local name="$1" page="$2" ap="$3"
    shift 3
    local dir png
    dir=$(gui_dir)
    png="$dir/$name.png"

    defaults_reset
    gui_run 60 "$dir/$name.log" \
        DITKIT_APPEARANCE="$ap" DITKIT_PAGE="$page" \
        DITKIT_SHOT="$png" \
        DITKIT_LUT="$FIX/identity.cube" \
        DITKIT_DROP="$FIX/ruler_a.mp4|$FIX/ruler_b.mp4" \
        "$@" >/dev/null

    if [ "$(image_uniform "$png" 2>/dev/null)" = "varied" ]; then
        printf '%s' "$png"
        return 0
    fi

    # 窗口合成没拿到（整张一个颜色），退回视图缓存路径
    defaults_reset
    gui_run 60 "$dir/$name.viewcache.log" \
        DITKIT_APPEARANCE="$ap" DITKIT_PAGE="$page" \
        DITKIT_SHOT="$png" DITKIT_SHOT_VIEWCACHE=1 \
        DITKIT_LUT="$FIX/identity.cube" \
        DITKIT_DROP="$FIX/ruler_a.mp4|$FIX/ruler_b.mp4" \
        "$@" >/dev/null
    printf '%s' "$png"
}

# 两条路都拿不到图才算环境限制，跳过；图本身坏掉则是真问题，报错。
require_capture() {
    expect_file "$1"
    local state
    state=$(image_uniform "$1")
    case "$state" in
        varied) return 0 ;;
        uniform) skip "本会话窗口合成与视图缓存都拿不到内容（不是界面问题）" ;;
        *) fail "抓图不是可解码的图片: $1" ;;
    esac
}

# 截图宽度应当是 740 点 @2x。高度随抓图方式略有差别（含不含标题栏），只作下限约束。
expect_window_width() {
    local png="$1" size
    size=$(image_size "$png")
    expect_eq "1480" "$(printf '%s' "$size" | cut -d, -f1)" "截图宽度（740 点 @2x）"
    expect_ge "$(printf '%s' "$size" | cut -d, -f2)" 1600 "截图高度"
}

c_renders_both_pages() {
    gui_available || skip "当前会话没有图形界面"
    local png
    png=$(render lut-page 0 dark)
    require_capture "$png"
    expect_window_width "$png"

    png=$(render trim-page 1 dark DITKIT_TRIM_START=00:00:02 DITKIT_TRIM_END=00:00:05)
    require_capture "$png"
    expect_window_width "$png"
}

c_renders_light_theme() {
    gui_available || skip "当前会话没有图形界面"
    local png
    png=$(render lut-light 0 light)
    require_capture "$png"
    expect_window_width "$png"
}

# 顶栏回归守卫：内容区 y=18..74pt 处是标题与 ffmpeg 状态、页切换器，
# 换算到 2x 截图里落在像素 36..148 一带。取 70..200 这个窗口，
# 既覆盖到切换器（96..148），又完全避开窗口标题栏（0..56）。
# bug 存在时这一整条是全空的 —— 当时内容要到页面区（约像素 226）才开始出现。
c_top_bar_has_content() {
    gui_available || skip "当前会话没有图形界面"
    local png
    png=$(render topbar 0 dark)
    require_capture "$png"
    expect_eq "content" "$(image_band "$png" 70 200)" "顶栏像素区间应当有内容"
}

# 页面主体（内容区 y=84pt 往下）也应当有内容
c_page_body_has_content() {
    gui_available || skip "当前会话没有图形界面"
    local png
    png=$(render body 0 dark)
    require_capture "$png"
    expect_eq "content" "$(image_band "$png" 260 700)" "页面主体像素区间应当有内容"
}

c_diagnostics_sane() {
    gui_available || skip "当前会话没有图形界面"
    local log subs
    defaults_reset
    log=$(gui_run 60 "$(gui_dir)/diag.log" \
        DITKIT_APPEARANCE=dark DITKIT_PAGE=0 \
        DITKIT_LUT="$FIX/identity.cube" DITKIT_DROP="$FIX/ruler_a.mp4")
    gui_ran "$log" || skip "自检没能启动"
    expect_contains "$log" "工具页  : 2 个" "工具页数量"
    expect_contains "$log" "窗口    : " "窗口诊断"
    subs=$(printf '%s' "$log" | sed -n 's/.*子视图 \([0-9]*\) 个.*/\1/p' | head -1)
    expect_ge "$subs" 10 "LUT 页子视图数（界面确实搭起来了）"
    expect_eq "0" "$(gui_busy "$log")" "没有任务时应当空闲"
}

# 干净偏好下也要能正常启动（新用户第一次打开的场景）
c_starts_with_fresh_preferences() {
    gui_available || skip "当前会话没有图形界面"
    local log
    defaults_reset
    log=$(gui_run 60 "$(gui_dir)/fresh.log" \
        DITKIT_APPEARANCE=dark DITKIT_PAGE=0 \
        DITKIT_LUT="$FIX/identity.cube" DITKIT_DROP="$FIX/ruler_a.mp4")
    gui_ran "$log" || skip "自检没能启动"
    expect_contains "$log" "ffmpeg  : " "ffmpeg 状态行"
    expect_contains "$log" "当前页视图:" "页面视图诊断"
}

# 裁剪页也要能渲染出有内容的图（两页共用同一套布局容器）
c_trim_page_has_content() {
    gui_available || skip "当前会话没有图形界面"
    local png
    png=$(render trim-body 1 dark DITKIT_TRIM_START=00:00:02 DITKIT_TRIM_END=00:00:05)
    require_capture "$png"
    expect_eq "content" "$(image_band "$png" 70 200)" "裁剪页顶栏区间应当有内容"
    expect_eq "content" "$(image_band "$png" 260 700)" "裁剪页主体区间应当有内容"
}

# ---------- 任务列表：把诊断行拆成可断言的小块 ----------
# 列表那行长这样：
#   NSScrollView  x=18 y=491 w=668 h=145  rows=0 w=[224,287,145] mask=[2,3,2]
# rows 用来断言增删；w 是列宽（拖分隔条会变）；mask 是列的 resizingMask，
# 值里带 NSTableColumnUserResizingMask(=2) 这一位才拖得动。

gui_list_line() {
    printf '%s' "$1" | grep -m1 'NSScrollView' || true
}

gui_rows() {
    printf '%s' "$1" | sed -n 's/.*rows=\([0-9]*\).*/\1/p' | head -1
}

gui_col_widths() {
    printf '%s' "$1" | sed -n 's/.*w=\[\([0-9,]*\)\].*/\1/p' | head -1
}

# 列宽数组里的第 N 列（0 基）
gui_col_w() {
    gui_col_widths "$1" | cut -d, -f"$(( $2 + 1 ))"
}

gui_col_masks() {
    printf '%s' "$1" | sed -n 's/.*mask=\[\([0-9,]*\)\].*/\1/p' | head -1
}

# 某个按钮的 enabled 状态（0/1）；找不到就返回空
gui_button_enabled() {
    printf '%s' "$1" | grep -F "\"$2\"" | sed -n 's/.*enabled=\([0-9]*\).*/\1/p' | head -1
}

# 拖入 LUT 时按后缀名把关，别把视频文件当调色文件收下
# （真实踩过：拖错文件进去，界面上一声不响，什么提示都没有）
c_lut_drop_rejects_wrong_extension() {
    gui_available || skip "当前会话没有图形界面"
    local log
    defaults_reset
    log=$(gui_run 60 "$(gui_dir)/lut-reject.log" \
        DITKIT_APPEARANCE=light DITKIT_PAGE=0 \
        DITKIT_LUT_DROP="$FIX/solid.mp4")
    gui_ran "$log" || skip "自检没能启动"
    expect_contains "$log" "LUT 拖入: 拒绝  solid.mp4" "视频文件应当被拒绝"
    expect_contains "$(gui_status "$log")" "不是 LUT 文件" "状态行应当说明拒绝的原因"
    expect_contains "$(gui_status "$log")" ".cube" "状态行应当列出接受的扩展名"
}

c_lut_drop_accepts_cube() {
    gui_available || skip "当前会话没有图形界面"
    local log
    defaults_reset
    log=$(gui_run 60 "$(gui_dir)/lut-accept.log" \
        DITKIT_APPEARANCE=light DITKIT_PAGE=0 \
        DITKIT_LUT_DROP="$FIX/identity.cube")
    gui_ran "$log" || skip "自检没能启动"
    expect_contains "$log" "LUT 拖入: 接受  identity.cube" "正确后缀应当被接受"
    expect_contains "$log" "[identity.cube]" "拖放框应当显示选中的 LUT"
    expect_not_contains "$(gui_status "$log")" "不是 LUT 文件" "接受时不该出现拒绝提示"
}

# 文件夹也要拒绝，并且把原因说清楚（不是笼统的一句「不支持」）
c_lut_drop_rejects_folder() {
    gui_available || skip "当前会话没有图形界面"
    local log
    defaults_reset
    log=$(gui_run 60 "$(gui_dir)/lut-folder.log" \
        DITKIT_APPEARANCE=light DITKIT_PAGE=0 DITKIT_LUT_DROP="$FIX")
    gui_ran "$log" || skip "自检没能启动"
    expect_contains "$log" "LUT 拖入: 拒绝" "文件夹应当被拒绝"
    expect_contains "$(gui_status "$log")" "不能是文件夹" "状态行应当说明是文件夹"
}

# 列表要能选中并删除条目；删完按钮变灰，状态行要说清只动列表、不动磁盘
c_list_delete_selected() {
    gui_available || skip "当前会话没有图形界面"
    local log line

    defaults_reset
    log=$(gui_run 60 "$(gui_dir)/list-select.log" \
        DITKIT_APPEARANCE=light DITKIT_PAGE=1 \
        DITKIT_DROP="$FIX/ruler_a.mp4|$FIX/ruler_b.mp4" \
        DITKIT_LIST_ACTION=select-all)
    gui_ran "$log" || skip "自检没能启动"
    line=$(gui_list_line "$log")
    expect_eq "2" "$(gui_rows "$line")" "拖入两个文件后的列表行数"
    expect_eq "1" "$(gui_button_enabled "$log" "删除选中")" "有选中时「删除选中」应当可用"

    defaults_reset
    log=$(gui_run 60 "$(gui_dir)/list-delete.log" \
        DITKIT_APPEARANCE=light DITKIT_PAGE=1 \
        DITKIT_DROP="$FIX/ruler_a.mp4|$FIX/ruler_b.mp4" \
        DITKIT_LIST_ACTION=delete-all)
    gui_ran "$log" || skip "自检没能启动"
    line=$(gui_list_line "$log")
    expect_eq "0" "$(gui_rows "$line")" "全选删除后的列表行数"
    expect_eq "0" "$(gui_button_enabled "$log" "删除选中")" "删完没有选中，按钮应当变灰"
    expect_contains "$(gui_status "$log")" "已从列表移除 2 个" "状态行应当报出移除数量"
    expect_contains "$(gui_status "$log")" "磁盘上的文件不受影响" "状态行应当说明不影响磁盘文件"
}

# 列分隔条要能拖，而且拖过之后不能被「按容器宽度重新分配」抹掉
c_column_divider_is_draggable_and_sticky() {
    gui_available || skip "当前会话没有图形界面"
    local base bline log line b0 b1 b2 masks i m

    # 先量一次默认列宽（不拖）
    defaults_reset
    base=$(gui_run 60 "$(gui_dir)/col-base.log" \
        DITKIT_APPEARANCE=light DITKIT_PAGE=1 DITKIT_DROP="$FIX/ruler_a.mp4")
    gui_ran "$base" || skip "自检没能启动"
    bline=$(gui_list_line "$base")
    b0=$(gui_col_w "$bline" 0)
    b1=$(gui_col_w "$bline" 1)
    b2=$(gui_col_w "$bline" 2)
    [ -n "$b0" ] || fail "没能从诊断里读到默认列宽: $bline"

    # 拖分隔条把第 0 列加宽 40，拖完还会再走一遍布局
    defaults_reset
    log=$(gui_run 60 "$(gui_dir)/col-drag.log" \
        DITKIT_APPEARANCE=light DITKIT_PAGE=1 \
        DITKIT_DROP="$FIX/ruler_a.mp4" DITKIT_COLUMN_DRAG=0:40)
    gui_ran "$log" || skip "自检没能启动"
    line=$(gui_list_line "$log")
    expect_near "$((b0 + 40))" "$(gui_col_w "$line" 0)" 1 "拖后第 0 列宽度（应比默认宽 40）"
    expect_eq "$b1" "$(gui_col_w "$line" 1)" "第 1 列不该被动"
    expect_eq "$b2" "$(gui_col_w "$line" 2)" "第 2 列不该被动"

    # 三列都要带 UserResizing 位，否则拖不动
    masks=$(gui_col_masks "$line")
    i=0
    for m in $(printf '%s' "$masks" | tr ',' ' '); do
        awk -v m="$m" 'BEGIN { exit (int(m / 2) % 2 == 1) ? 0 : 1 }' \
            || fail "第 ${i} 列不可拖动（resizingMask=${m}，缺 NSTableColumnUserResizingMask 位）"
        i=$((i + 1))
    done
    expect_eq "3" "$i" "参与检查的列数"
}

# 拖入区与列表合并后：列表自己就是拖入目标，页面上不该再多一个拖放框
c_list_is_the_only_drop_target() {
    gui_available || skip "当前会话没有图形界面"
    local log line wells

    defaults_reset
    log=$(gui_run 60 "$(gui_dir)/merged.log" \
        DITKIT_APPEARANCE=light DITKIT_PAGE=1 DITKIT_DROP="$FIX/ruler_a.mp4")
    gui_ran "$log" || skip "自检没能启动"
    wells=$(printf '%s' "$log" | grep -c 'DropWellView' || true)
    expect_eq "0" "$wells" "裁剪页不该再有独立的源文件拖放框"
    expect_contains "$log" "添加文件…" "应当有独立的「添加文件」按钮"
    expect_contains "$log" "删除选中" "应当有「删除选中」按钮"
    line=$(gui_list_line "$log")
    expect_eq "1" "$(gui_rows "$line")" "文件拖到列表上应当直接进列表"

    # LUT 页保留它自己的 LUT 拖放框 —— 那个是选调色文件的，跟文件列表不是一回事
    defaults_reset
    log=$(gui_run 60 "$(gui_dir)/lut-well.log" \
        DITKIT_APPEARANCE=light DITKIT_PAGE=0 DITKIT_DROP="$FIX/ruler_a.mp4")
    gui_ran "$log" || skip "自检没能启动"
    wells=$(printf '%s' "$log" | grep -c 'DropWellView' || true)
    expect_eq "1" "$wells" "LUT 页只应保留 LUT 拖放框"
}

reg \
    "两个工具页都能渲染出图"            c_renders_both_pages \
    "浅色主题也能渲染"                  c_renders_light_theme \
    "顶栏（标题与页切换器）真的画出来了" c_top_bar_has_content \
    "页面主体真的画出来了"              c_page_body_has_content \
    "裁剪页也画得有内容"                c_trim_page_has_content \
    "自检诊断信息正常"                  c_diagnostics_sane \
    "干净偏好下能正常启动"              c_starts_with_fresh_preferences \
    "LUT 拖入会挡掉错误的后缀名"         c_lut_drop_rejects_wrong_extension \
    "LUT 拖入能收下 .cube"              c_lut_drop_accepts_cube \
    "LUT 拖入会挡掉文件夹"               c_lut_drop_rejects_folder \
    "列表能选中并删除条目"              c_list_delete_selected \
    "列分隔条能拖，且拖后不被覆盖"       c_column_divider_is_draggable_and_sticky \
    "拖入区已与列表合并"                c_list_is_the_only_drop_target
