#!/usr/bin/env bash
# DITKit 测试套件入口
#
#   ./tests/run.sh                    跑全部
#   ./tests/run.sh --list             只列用例
#   ./tests/run.sh --filter 裁剪      只跑名字/组里含「裁剪」的
#   ./tests/run.sh --refresh-fixtures 重新合成素材
#   ./tests/run.sh --verbose          通过的用例也打印输出
#
# 输出是 TAP 风格的 ok / not ok，方便接 CI；退出码 0 表示全过。
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$TESTS_DIR/lib.sh"

FILTER=""
LIST_ONLY=0
VERBOSE=0
REFRESH_FIXTURES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --list) LIST_ONLY=1 ;;
        --verbose | -v) VERBOSE=1 ;;
        --refresh-fixtures) REFRESH_FIXTURES=1 ;;
        --filter) shift; FILTER="${1:-}" ;;
        --filter=*) FILTER="${1#--filter=}" ;;
        -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $1（--help 看用法）" >&2; exit 2 ;;
    esac
    shift
done

mkdir -p "$WORK/run"

# ---------- 载入用例 ----------
shopt -s nullglob
CASE_FILES=("$CASES_DIR"/*.sh)
shopt -u nullglob
if [ ${#CASE_FILES[@]} -eq 0 ]; then
    echo "没找到用例文件（$CASES_DIR/*.sh）" >&2
    exit 1
fi
for f in "${CASE_FILES[@]}"; do
    # shellcheck source=/dev/null
    source "$f"
done

if [ "$LIST_ONLY" = "1" ]; then
    for i in "${!CASE_FUNC[@]}"; do
        printf '%2d. %-14s %s\n' "$((i + 1))" "${CASE_GROUP[$i]}" "${CASE_NAME[$i]}"
    done
    printf '\n共 %d 个用例\n' "${#CASE_FUNC[@]}"
    exit 0
fi

# ---------- 前置条件 ----------
require_tools || exit 1
echo "DITKit 测试套件"
echo "  应用   : $BIN"
echo "  ffmpeg : $($FFMPEG -version 2>/dev/null | head -1 | cut -d' ' -f1-3)"
echo "  用例   : ${#CASE_FUNC[@]} 个"
[ -n "$FILTER" ] && echo "  筛选   : $FILTER"

if [ "$REFRESH_FIXTURES" = "1" ]; then
    rm -f "$FIX/.stamp"
fi
ensure_fixtures || exit 1
echo "  素材   : $FIX"
echo

# ---------- 跑 ----------
LOG="$WORK/last-run.log"
: >"$LOG"

PASS=0
FAIL=0
SKIP=0
IDX=0
FAILED_NAMES=()
T0=$(date +%s)

for i in "${!CASE_FUNC[@]}"; do
    grp="${CASE_GROUP[$i]}"
    name="${CASE_NAME[$i]}"
    fn="${CASE_FUNC[$i]}"

    if [ -n "$FILTER" ] && [[ "$grp/$name" != *"$FILTER"* ]]; then
        continue
    fi

    IDX=$((IDX + 1))
    label="$grp · $name"

    out="$(set -e; "$fn" 2>&1)"
    rc=$?

    case "$rc" in
        0)
            PASS=$((PASS + 1))
            if [ "$VERBOSE" = "1" ] && [ -n "$out" ]; then
                printf 'ok %d - %s\n' "$IDX" "$label"
                printf '%s\n' "$out" | sed 's/^/#     /'
            else
                printf 'ok %d - %s\n' "$IDX" "$label"
            fi
            ;;
        77)
            SKIP=$((SKIP + 1))
            reason="$(printf '%s' "$out" | head -1)"
            printf 'ok %d - %s # SKIP %s\n' "$IDX" "$label" "$reason"
            ;;
        *)
            FAIL=$((FAIL + 1))
            FAILED_NAMES+=("$label")
            printf 'not ok %d - %s\n' "$IDX" "$label"
            if [ -n "$out" ]; then
                printf '%s\n' "$out" | sed 's/^/#     /'
            else
                printf '#     用例以 %d 退出，但没有输出原因\n' "$rc"
            fi
            ;;
    esac

    # 格式串不要以 '-' 开头，否则 bash 的 printf 会把它当选项（踩过）
    printf '%s\n' "--- ${label} rc=${rc}" >>"$LOG"
    [ -n "$out" ] && printf '%s\n' "$out" >>"$LOG"
done

T1=$(date +%s)
DUR=$((T1 - T0))

echo
echo "────────────────────────────────────────────────"
if [ "$FAIL" -gt 0 ]; then
    echo "失败用例:"
    for n in "${FAILED_NAMES[@]}"; do
        printf '  · %s\n' "$n"
    done
    echo "────────────────────────────────────────────────"
fi
printf '总计 %d   通过 %d   失败 %d   跳过 %d   用时 %ds\n' \
    "$((PASS + FAIL + SKIP))" "$PASS" "$FAIL" "$SKIP" "$DUR"
echo "详细日志: $LOG"

[ "$FAIL" -eq 0 ]
