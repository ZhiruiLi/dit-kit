#!/usr/bin/env bash
# 测试套件的断言库与公共环境。
# 由 tests/run.sh 和 tests/cases/*.sh source，不要直接执行。

# ---------- 路径 ----------
# lib.sh 在 tests/ 下，工程根是它的上一级
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
BIN="$ROOT/build/DITKit.app/Contents/MacOS/DITKit"
WORK="$TESTS_DIR/work"           # 全部中间产物都在这里，已在 .gitignore 里排除
FIX="$WORK/fixtures"             # 素材缓存
# 注意：这个目录名不能带前导点。应用会把「路径里含隐藏目录」的输入当作
# 隐藏文件跳过（合理行为），素材若放在 .work/ 下就会一个都处理不了。
CASES_DIR="$TESTS_DIR/cases"
PROBE="$TESTS_DIR/helpers/probe.py"

# ---------- 外部工具 ----------
# 优先从 PATH 里找，找不到再退回 Homebrew 默认前缀；也可用 FFMPEG/FFPROBE 覆盖
FFMPEG="${FFMPEG:-$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)}"
FFPROBE="${FFPROBE:-$(command -v ffprobe || echo /opt/homebrew/bin/ffprobe)}"
PYTHON="${PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"

# ---------- 用例注册 ----------
# 每个 case 文件开头设 GROUP，结尾用 reg 把「描述 → 函数」登记进来。
# 登记顺序就是执行顺序，不依赖任何反射。
CASE_GROUP=()
CASE_NAME=()
CASE_FUNC=()
GROUP=""

reg() {
    while [ $# -ge 2 ]; do
        CASE_GROUP+=("$GROUP")
        CASE_NAME+=("$1")
        CASE_FUNC+=("$2")
        shift 2
    done
}

# ---------- 断言 ----------
# 约定：断言成功时悄悄返回 0；失败时打印原因并返回非 0。
# run.sh 会在 set -e 的子 shell 里调用用例函数，所以第一个失败就会中止该用例。

fail() {
    printf '✗ %s\n' "$*" >&2
    return 1
}

note() {
    printf '· %s\n' "$*" >&2
}

skip() {
    printf '%s\n' "$*" >&2
    exit 77
}

expect_eq() {
    local want="$1" got="$2" label="${3:-值}"
    [ "$want" = "$got" ] || fail "$label 期望=[$want] 实际=[$got]"
}

expect_ne() {
    local a="$1" b="$2" label="${3:-值}"
    [ "$a" != "$b" ] || fail "$label 期望不等于 [$b]，但实际相等"
}

# 注意：变量后面紧跟全角字符时必须写成 ${var}。
# 不加花括号时 bash 会把多字节字符的字节当成变量名的一部分（这个坑踩过两次）。
expect_contains() {
    local hay="$1" needle="$2" label="${3:-输出}"
    case "$hay" in
        *"$needle"*) ;;
        *) fail "${label} 里没有「${needle}」；实际: $(printf '%s' "$hay" | tr '\n' ' ' | cut -c1-200)" ;;
    esac
}

expect_not_contains() {
    local hay="$1" needle="$2" label="${3:-输出}"
    case "$hay" in
        *"$needle"*) fail "${label} 里不该出现「${needle}」；实际: $(printf '%s' "$hay" | tr '\n' ' ' | cut -c1-200)" ;;
    esac
}

expect_file() {
    [ -f "$1" ] || fail "文件不存在: $1"
}

expect_no_file() {
    [ ! -e "$1" ] || fail "文件不该存在: $1"
}

expect_dir() {
    [ -d "$1" ] || fail "目录不存在: $1"
}

# 数值比较，用 awk 以免依赖 bc
expect_near() {
    local want="$1" got="$2" tol="$3" label="${4:-数值}"
    [ -n "$got" ] || fail "$label 没取到值（空）"
    awk -v w="$want" -v g="$got" -v t="$tol" \
        'BEGIN { d = w - g; if (d < 0) d = -d; exit (d <= t) ? 0 : 1 }' \
        || fail "${label} 期望≈${want}（容差 ±${tol}）实际=${got}"
}

expect_ge() {
    local got="$1" min="$2" label="${3:-数值}"
    awk -v g="$got" -v m="$min" 'BEGIN { exit (g >= m) ? 0 : 1 }' \
        || fail "${label} 期望 >= ${min}，实际=${got}"
}

expect_le() {
    local got="$1" max="$2" label="${3:-数值}"
    awk -v g="$got" -v m="$max" 'BEGIN { exit (g <= m) ? 0 : 1 }' \
        || fail "${label} 期望 <= ${max}，实际=${got}"
}

# 逐通道比较两组 "R G B" 读数
expect_rgb_near() {
    local want="$1" got="$2" tol="$3" label="${4:-颜色}"
    awk -v a="$want" -v b="$got" -v t="$tol" -v label="$label" 'BEGIN {
        n = split(a, p, " "); m = split(b, q, " ")
        if (n < 3 || m < 3) {
            printf "✗ %s 颜色读数不完整 期望=[%s] 实际=[%s]\n", label, a, b > "/dev/stderr"
            exit 1
        }
        for (i = 1; i <= 3; i++) {
            d = p[i] - q[i]; if (d < 0) d = -d
            if (d > t) {
                printf "✗ %s 期望=[%s] 实际=[%s]（第 %d 通道差 %d，容差 %d）\n", label, a, b, i, d, t > "/dev/stderr"
                exit 1
            }
        }
    }'
}

# ---------- 执行辅助 ----------
# 捕获输出且不让非零退出码打断用例（配合 set -e 使用）
run() {
    local o
    o="$("$@" 2>&1)" || true
    printf '%s' "$o"
}

# 只关心退出码
exit_code() {
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
}

# 跑一段命令并同时断言退出码与输出里的关键词。
# 用法: expect_error <退出码> <输出里必须出现的文本> -- <命令...>
expect_error() {
    local want="$1" text="$2"; shift 2
    [ "${1:-}" = "--" ] && shift
    local rc=0 out=""
    out="$("$@" 2>&1)" || rc=$?
    [ "$rc" = "$want" ] || fail "退出码 期望=$want 实际=$rc  命令: $*"
    expect_contains "$out" "$text" "错误输出"
}

# ---------- 媒体辅助 ----------
probe_duration() {
    "$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null | head -1
}

probe_vcodec() {
    "$FFPROBE" -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$1" 2>/dev/null | head -1
}

probe_pixfmt() {
    "$FFPROBE" -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$1" 2>/dev/null | head -1
}

# 首个视频包的 flags（含 K 表示是关键帧）。流复制模式下用它验证「回退到关键帧」。
probe_first_packet_flags() {
    "$FFPROBE" -v error -select_streams v:0 -show_entries packet=flags -of csv=p=0 "$1" 2>/dev/null | head -1
}

# 视频流的帧数
probe_vframes() {
    "$FFPROBE" -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$1" 2>/dev/null | head -1
}

# 图片的 "宽,高"
image_size() {
    "$FFPROBE" -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$1" 2>/dev/null | head -1
}

# 取某时刻一帧的均值 RGB，输出 "R G B"
frame_rgb() {
    "$PYTHON" "$PROBE" frame "$1" "$2"
}

# 取某时刻一帧，在时间码标尺调色板里找最接近的第几秒，输出 "序号 R G B 距离"
# 参数: <视频> <时刻> [调色板 tsv，默认用素材里的]
ruler_index() {
    "$PYTHON" "$PROBE" nearest "$1" "$2" "${3:-$FIX/colors.tsv}"
}

# 只在第 N 个字段上取整（ruler_index 返回 4 个字段）
ruler_second() {
    ruler_index "$1" "$2" "${3:-$FIX/colors.tsv}" | awk '{print $1}'
}

# 判断 PNG 的 [y0,y1) 像素行区间里有没有内容，输出 content 或 blank
image_band() {
    "$PYTHON" "$PROBE" band "$1" "$2" "$3"
}

# 整张图是否只有一个颜色，输出 uniform 或 varied。
# 用来区分「本次会话拿不到窗口合成（抓图全黑）」与「界面真的画错了」。
image_uniform() {
    "$PYTHON" "$PROBE" uniform "$1"
}

# ---------- 标尺 ----------
# 段长（秒）。真源在素材目录的 band.txt 里，由 mkfixtures.sh 写出，
# 免得生成端与断言端各写一个常数。
band_sec() {
    cat "$FIX/band.txt" 2>/dev/null || echo 0.5
}

# 取调色板里第 idx 号颜色的 "R G B"
palette_rgb() {
    awk -v i="$1" 'NR == i + 1 { print $2, $3, $4 }' "$FIX/colors.tsv"
}

# 源时间 t 时刻，标尺应该是调色板里的第几号颜色
ruler_expected() {
    awk -v t="$1" -v b="$(band_sec)" 'BEGIN { printf "%d", int(t / b) % 10 }'
}

# 读一个「R G B」参考文件（允许最前面多一列序号）
read_rgb() {
    awk '{ print $(NF - 2), $(NF - 1), $NF }' "$1"
}

# ---------- 素材 ----------
# 生成（或复用）测试素材。素材完全由 ffmpeg lavfi 合成，不依赖任何外部文件，
# 因此换一台机器也能跑出同样的结果。
ensure_fixtures() {
    if [ -f "$FIX/.stamp" ] && [ "${REFRESH_FIXTURES:-0}" != "1" ]; then
        return 0
    fi
    bash "$TESTS_DIR/mkfixtures.sh"
}

# 每个用例一个干净的工作目录
fresh_dir() {
    local d="$WORK/run/$1"
    rm -rf "$d"
    mkdir -p "$d"
    printf '%s' "$d"
}

# ---------- 环境自检 ----------
require_tools() {
    local missing=()
    [ -x "$BIN" ] || missing+=("${BIN}（先跑 ./build.sh）")
    [ -x "$FFMPEG" ] || missing+=("ffmpeg（brew install ffmpeg）")
    [ -x "$FFPROBE" ] || missing+=("ffprobe")
    [ -x "$PYTHON" ] || missing+=("python3")
    if [ ${#missing[@]} -gt 0 ]; then
        printf '缺少运行条件:\n' >&2
        printf '  - %s\n' "${missing[@]}" >&2
        return 1
    fi
    return 0
}

# ---------- 偏好设置 ----------
DEFAULTS_DOMAIN="local.tools.ditkit"

defaults_reset() {
    defaults delete "$DEFAULTS_DOMAIN" >/dev/null 2>&1 || true
}

defaults_set_int() { defaults write "$DEFAULTS_DOMAIN" "$1" -int "$2"; }
defaults_set_str() { defaults write "$DEFAULTS_DOMAIN" "$1" -string "$2"; }
defaults_set_bool() { defaults write "$DEFAULTS_DOMAIN" "$1" -bool "$2"; }

# ---------- 界面自检 ----------
# 跑一次 --selftest，带看门狗（macOS 没有 timeout 命令，自己轮询）。
# 用法: gui_run <超时秒> <日志文件> <环境赋值...>
# 环境赋值形如 DITKIT_PAGE=0，会以独立 argv 传给 env，所以值里有空格也不要紧。
gui_run() {
    local timeout="$1" log="$2"
    shift 2
    : >"$log"
    env "$@" "$BIN" --selftest >"$log" 2>&1 &
    local pid=$!
    local ticks=0
    local limit=$((timeout * 10))
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge "$limit" ]; then
            kill -9 "$pid" 2>/dev/null || true
            printf '看门狗: 超过 %s 秒仍未退出，已强杀\n' "$timeout" >>"$log"
            break
        fi
        sleep 0.1
        ticks=$((ticks + 1))
    done
    wait "$pid" 2>/dev/null || true
    cat "$log"
}

# 从自检日志里取「运行态 : busy=0  状态行=...」
gui_busy() {
    printf '%s' "$1" | grep -m1 '运行态' | sed -n 's/.*busy=\([0-9]*\).*/\1/p'
}

gui_status() {
    printf '%s' "$1" | grep -m1 '运行态' | sed -n 's/.*状态行=//p'
}

# 界面自检需要窗口服务；纯 SSH / 后台会话下应当跳过而不是报错。
# launchctl 的 manager 名为 Aqua 才说明身处图形登录会话。
gui_available() {
    local mgr
    mgr="$(launchctl managername 2>/dev/null || echo unknown)"
    [ "$mgr" = "Aqua" ]
}

# 自检是否真的跑起来了（日志里有诊断块）
gui_ran() {
    case "$1" in
        *"=== 自检"*) return 0 ;;
        *) return 1 ;;
    esac
}

# 有没有残留的 ffmpeg 进程（按输出目录特征匹配）
leftover_ffmpeg() {
    pgrep -f "$1" 2>/dev/null | wc -l | tr -d ' '
}

