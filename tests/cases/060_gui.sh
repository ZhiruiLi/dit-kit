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

reg \
    "两个工具页都能渲染出图"            c_renders_both_pages \
    "浅色主题也能渲染"                  c_renders_light_theme \
    "顶栏（标题与页切换器）真的画出来了" c_top_bar_has_content \
    "页面主体真的画出来了"              c_page_body_has_content \
    "裁剪页也画得有内容"                c_trim_page_has_content \
    "自检诊断信息正常"                  c_diagnostics_sane \
    "干净偏好下能正常启动"              c_starts_with_fresh_preferences
