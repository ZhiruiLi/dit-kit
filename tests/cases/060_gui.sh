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

    png=$(render audio-page 2 dark DITKIT_AUDIO_START=00:00:01 DITKIT_AUDIO_END=00:00:03)
    require_capture "$png"
    expect_window_width "$png"

    png=$(render mask-page 3 dark \
        DITKIT_IMAGE="$FIX/ov_small_green.png" DITKIT_OVERLAY_FIT=contain)
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
    expect_contains "$log" "工具页  : 4 个" "工具页数量"
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

# 裁剪页也要能渲染出有内容的图（三页共用同一套布局容器）
c_trim_page_has_content() {
    gui_available || skip "当前会话没有图形界面"
    local png
    png=$(render trim-body 1 dark DITKIT_TRIM_START=00:00:02 DITKIT_TRIM_END=00:00:05)
    require_capture "$png"
    expect_eq "content" "$(image_band "$png" 70 200)" "裁剪页顶栏区间应当有内容"
    expect_eq "content" "$(image_band "$png" 260 700)" "裁剪页主体区间应当有内容"
}

# 音频页：渲染有内容、列表同样是拖入区、源信息会报出音频流概况。
# 两个素材都复制成短名字并放进同一个目录 —— 源信息取列表里第一个文件，
# 而诊断行会把标签截到 26 个字符，用长文件名就把「音频概况」整段截掉了。
c_audio_page_works() {
    gui_available || skip "当前会话没有图形界面"
    local d png log line
    d=$(fresh_dir gui-audio)
    cp "$FIX/tone_ruler.m4a" "$d/a.m4a"
    cp "$FIX/tone_ruler.mp4" "$d/b.mp4"

    png=$(render audio-body 2 dark DITKIT_AUDIO_START=00:00:01 DITKIT_AUDIO_END=00:00:03)
    require_capture "$png"
    expect_eq "content" "$(image_band "$png" 70 200)" "音频页顶栏区间应当有内容"
    expect_eq "content" "$(image_band "$png" 260 700)" "音频页主体区间应当有内容"

    defaults_reset
    log=$(gui_run 60 "$(gui_dir)/audio-list.log" \
        DITKIT_APPEARANCE=light DITKIT_PAGE=2 \
        DITKIT_DROP="$d/a.m4a|$d/b.mp4")
    gui_ran "$log" || skip "自检没能启动"
    expect_contains "$log" "[2] 音频提取" "页切换器上应当有音频页"
    line=$(gui_list_line "$log")
    expect_eq "2" "$(gui_rows "$line")" "拖入两个文件后的列表行数"
    expect_contains "$log" "aac 48kHz 单声道" "源信息应当报出音频流概况"
}

# 遮罩页：渲染有内容、合成静帧真的出图、诊断行报出用的是哪张图
c_mask_page_works() {
    gui_available || skip "当前会话没有图形界面"
    local png log line
    png=$(render mask-body 3 dark \
        DITKIT_IMAGE="$FIX/ov_small_green.png" DITKIT_OVERLAY_FIT=contain)
    require_capture "$png"
    expect_eq "content" "$(image_band "$png" 70 200)" "遮罩页顶栏区间应当有内容"
    expect_eq "content" "$(image_band "$png" 260 700)" "遮罩页主体区间应当有内容"

    defaults_reset
    log=$(gui_run 60 "$(gui_dir)/mask-info.log" \
        DITKIT_APPEARANCE=light DITKIT_PAGE=3 DITKIT_SHOT_DELAY=2.5 \
        DITKIT_DROP="$FIX/ruler_a.mp4" DITKIT_IMAGE="$FIX/ov_small_green.png")
    gui_ran "$log" || skip "自检没能启动"
    expect_contains "$log" "[3] 图片遮罩" "页切换器上应当有遮罩页"
    line=$(gui_preview_line "$log")
    expect_contains "$line" "遮罩=ov_small_green.png" "诊断行应当报出用的哪张图"
    expect_contains "$line" "构图=stretch/normal/100" "默认应当是拉伸铺满、普通混合、100%"
    expect_eq "ok" "$(gui_preview_field "$line" 合成)" "合成静帧应当成功"

    # 没选图片时也给一张源画面，而不是一片空白
    defaults_reset
    log=$(gui_run 60 "$(gui_dir)/mask-noimage.log" \
        DITKIT_APPEARANCE=light DITKIT_PAGE=3 DITKIT_SHOT_DELAY=2.5 \
        DITKIT_DROP="$FIX/ruler_a.mp4")
    gui_ran "$log" || skip "自检没能启动"
    line=$(gui_preview_line "$log")
    expect_contains "$line" "遮罩=无" "没选图时应当说明没有遮罩"
    expect_eq "ok" "$(gui_preview_field "$line" 合成)" "没选图时也该给一张源画面"
}

# 预览源规则：批量时默认取列表里第一个，只有唯一选中项时才换成选中的那个。
#
# 列表是按文件名词典序排的（不是拖入顺序），所以这里故意按 b、a 的顺序拖入：
# 预览取到 a 才说明它取的是「列表第一行」，而不是「第一个拖进来的」。
c_preview_source_follows_selection() {
    gui_available || skip "当前会话没有图形界面"
    local log line

    defaults_reset
    log=$(gui_run 60 "$(gui_dir)/preview-first.log" \
        DITKIT_APPEARANCE=light DITKIT_PAGE=3 DITKIT_SHOT_DELAY=2.5 \
        DITKIT_DROP="$FIX/ruler_b.mp4|$FIX/ruler_a.mp4" \
        DITKIT_IMAGE="$FIX/ov_full_red.png")
    gui_ran "$log" || skip "自检没能启动"
    expect_eq "2" "$(gui_rows "$(gui_list_line "$log")")" "拖入两个文件后的列表行数"
    line=$(gui_preview_line "$log")
    expect_contains "$line" "源=ruler_a.mp4（首个）" "没有选中时取列表第一个（与拖入顺序无关）"
    expect_eq "ok" "$(gui_preview_field "$line" 合成)" "预览应当合成成功"

    # 只有唯一选中项时，预览换成它
    defaults_reset
    log=$(gui_run 60 "$(gui_dir)/preview-select.log" \
        DITKIT_APPEARANCE=light DITKIT_PAGE=3 DITKIT_SHOT_DELAY=2.5 \
        DITKIT_DROP="$FIX/ruler_b.mp4|$FIX/ruler_a.mp4" \
        DITKIT_IMAGE="$FIX/ov_full_red.png" DITKIT_LIST_ACTION=select:1)
    gui_ran "$log" || skip "自检没能启动"
    line=$(gui_preview_line "$log")
    expect_contains "$line" "源=ruler_b.mp4（选中）" "唯一选中项应当优先被预览"
    note "  选中第 1 行: $line"
}

# 选中多行不算「指定了一个」：退回列表第一个
c_preview_ignores_multi_selection() {
    gui_available || skip "当前会话没有图形界面"
    local log line
    defaults_reset
    log=$(gui_run 60 "$(gui_dir)/preview-multi.log" \
        DITKIT_APPEARANCE=light DITKIT_PAGE=3 DITKIT_SHOT_DELAY=2.5 \
        DITKIT_DROP="$FIX/ruler_b.mp4|$FIX/ruler_a.mp4" \
        DITKIT_IMAGE="$FIX/ov_full_red.png" DITKIT_LIST_ACTION=select-all)
    gui_ran "$log" || skip "自检没能启动"
    line=$(gui_preview_line "$log")
    expect_contains "$line" "源=ruler_a.mp4（首个）" "全选时应当退回列表第一个"
}

# 音频页同样有预览：波形 + 选中区间高亮，且源跟着选中走
c_audio_page_previews_waveform() {
    gui_available || skip "当前会话没有图形界面"
    local log line

    # 故意按 mp4、m4a 的顺序拖入：列表按文件名字典序排，首个是 m4a，
    # 取到 m4a 才说明「首个」指的是列表第一行而不是第一个拖进来的。
    # （m4a 是纯音频输入，顺带覆盖「音频进、波形出」）
    defaults_reset
    log=$(gui_run 60 "$(gui_dir)/wave.log" \
        DITKIT_APPEARANCE=light DITKIT_PAGE=2 DITKIT_SHOT_DELAY=2.5 \
        DITKIT_DROP="$FIX/tone_ruler.mp4|$FIX/tone_ruler.m4a" \
        DITKIT_AUDIO_START=00:00:01 DITKIT_AUDIO_END=00:00:03)
    gui_ran "$log" || skip "自检没能启动"
    line=$(gui_preview_line "$log")
    expect_contains "$line" "源=tone_ruler.m4a（首个）" "没有选中时取列表第一个（与拖入顺序无关）"
    expect_eq "ok" "$(gui_preview_field "$line" 波形)" "波形应当画出来了"
    expect_contains "$line" "区间=00:00:01.000→00:00:03.000" "诊断行应当报出选中的区间"
    # 6 秒素材取 1→3 秒，高亮带应当从 1/6 处开始、宽 1/3（容器宽 668）
    expect_near "112" "$(printf '%s' "$line" | sed -n 's/.*带=\([0-9.]*\)+.*/\1/p')" 3 \
        "高亮带起点"
    expect_near "223" "$(printf '%s' "$line" | sed -n 's/.*带=[0-9.]*+\([0-9.]*\)\/.*/\1/p')" 3 \
        "高亮带宽度"

    # 源跟着选中走。
    # 注意列表是按文件名字典序排的（不是拖入顺序）：「tone_ruler.m4a」排在
    # 「tone_ruler.mp4」前面，所以第 0 行是 m4a、第 1 行是 mp4。
    defaults_reset
    log=$(gui_run 60 "$(gui_dir)/wave-select.log" \
        DITKIT_APPEARANCE=light DITKIT_PAGE=2 DITKIT_SHOT_DELAY=2.5 \
        DITKIT_DROP="$FIX/tone_ruler.mp4|$FIX/tone_ruler.m4a" \
        DITKIT_AUDIO_START=00:00:01 DITKIT_AUDIO_END=00:00:03 DITKIT_LIST_ACTION=select:1)
    gui_ran "$log" || skip "自检没能启动"
    line=$(gui_preview_line "$log")
    expect_contains "$line" "源=tone_ruler.mp4（选中）" "唯一选中项应当优先画波形"

    # 没有音频流时明确说明，而不是给一条空白的波形
    defaults_reset
    log=$(gui_run 60 "$(gui_dir)/wave-none.log" \
        DITKIT_APPEARANCE=light DITKIT_PAGE=2 DITKIT_SHOT_DELAY=2.5 \
        DITKIT_DROP="$FIX/silent.mp4")
    gui_ran "$log" || skip "自检没能启动"
    line=$(gui_preview_line "$log")
    expect_contains "$line" "波形=没有音频流" "没有音频流时应当说明原因"
}

# ---------- 任务列表：把诊断行拆成可断言的小块 ----------# 列表那行长这样：
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

# 列表自己就是拖入目标：每个工具页上只该有这一个拖放框
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

# 遮罩页是控件最多的页，预览和文件列表抢同一段竖直空间。
# 这里盯住分配结果：预览要够大、列表要够放下表头两行、而且谁都不能压住底部操作栏。
c_mask_page_layout_reserves_room() {
    gui_available || skip "当前会话没有图形界面"
    local log pageH pv list status btn
    local pvY pvH listY listH statusY btnY

    defaults_reset
    log=$(gui_run 60 "$(gui_dir)/mask-layout.log" \
        DITKIT_APPEARANCE=dark DITKIT_PAGE=3 DITKIT_SHOT_DELAY=2.5 \
        DITKIT_DROP="$FIX/ruler_a.mp4|$FIX/solid.mp4" \
        DITKIT_IMAGE="$FIX/ov_small_green.png")
    gui_ran "$log" || skip "自检没能启动"

    pageH=$(printf '%s' "$log" | sed -n 's/.*LayoutView *[0-9]* x \([0-9]*\).*/\1/p' | head -1)
    expect_ge "$pageH" "600" "页面可用高度"

    # 预览：合成静帧要看得清，给不到 96 就成了摆设
    pv=$(gui_subview_rect "$log" 'NSImageView')
    pvY=$(gui_rect_field "$pv" 2)
    pvH=$(gui_rect_field "$pv" 4)
    expect_ge "$pvH" "96" "预览静帧高度"

    # 列表：表头加两行，低于 80 就会出现半行被裁
    list=$(gui_subview_rect "$log" 'NSScrollView')
    listY=$(gui_rect_field "$list" 2)
    listH=$(gui_rect_field "$list" 4)
    expect_ge "$listH" "80" "文件列表高度"

    # 列表底边不能碰到底部操作栏的状态行
    status=$(gui_subview_rect "$log" 'NSTextField.*"就绪"')
    statusY=$(gui_rect_field "$status" 2)
    expect_ne "" "$statusY" "应当能在诊断里找到状态行"
    expect_ge "$((statusY - listY - listH))" "1" "列表底边到状态行的间隙"

    # 整页也不该溢出：最下面那个按钮连同 18pt 页边距要落在页面里
    btn=$(gui_subview_rect "$log" 'NSButton.*"开始合成"')
    btnY=$(gui_rect_field "$btn" 2)
    expect_le "$((btnY + 30 + 18))" "$pageH" "底部按钮栏未溢出页面"

    # 预览在列表上方，两者不该交叠
    expect_le "$((pvY + pvH))" "$listY" "预览底边在列表上方"
}

reg \
    "四个工具页都能渲染出图"            c_renders_both_pages \
    "浅色主题也能渲染"                  c_renders_light_theme \
    "顶栏（标题与页切换器）真的画出来了" c_top_bar_has_content \
    "页面主体真的画出来了"              c_page_body_has_content \
    "裁剪页也画得有内容"                c_trim_page_has_content \
    "音频页也画得有内容且列表可用"       c_audio_page_works \
    "遮罩页也画得有内容，合成静帧出图"    c_mask_page_works \
    "遮罩页给预览和列表各留出空间"        c_mask_page_layout_reserves_room \
    "预览源跟着唯一选中项走"            c_preview_source_follows_selection \
    "选中多行不算指定一个"              c_preview_ignores_multi_selection \
    "音频页有波形与区间高亮预览"         c_audio_page_previews_waveform \
    "自检诊断信息正常"                  c_diagnostics_sane \
    "干净偏好下能正常启动"              c_starts_with_fresh_preferences \
    "LUT 拖入会挡掉错误的后缀名"         c_lut_drop_rejects_wrong_extension \
    "LUT 拖入能收下 .cube"              c_lut_drop_accepts_cube \
    "LUT 拖入会挡掉文件夹"               c_lut_drop_rejects_folder \
    "列表能选中并删除条目"              c_list_delete_selected \
    "列分隔条能拖，且拖后不被覆盖"       c_column_divider_is_draggable_and_sticky \
    "列表是页面上唯一的拖入区"           c_list_is_the_only_drop_target
