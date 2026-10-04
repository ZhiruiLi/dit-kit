#!/usr/bin/env bash
# =============================================================================
# apply-lut.sh —— 批量给视频套用 LUT（针对 macOS Apple Silicon 优化）
#
# 依赖：ffmpeg  ->  brew install ffmpeg
#
# 快速开始：
#   mkdir -p input output
#   cp ~/Downloads/Look.cube ./look.cube
#   cp <你的视频> input/
#   bash apply-lut.sh
#
# 常用环境变量（放在命令前面即可）：
#   LUT=./SLog3_to_709.cube bash apply-lut.sh      # 指定 LUT
#   INDIR=~/Movies/log OUTDIR=~/Movies/graded bash apply-lut.sh
#   JOBS=3 bash apply-lut.sh                        # 并行 3 个文件
#   VQ=65 bash apply-lut.sh                         # 画质拉高
#   OVERWRITE=1 bash apply-lut.sh                   # 覆盖已有输出
#   VF_PRE='zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=p=bt709:t=bt709:m=bt709'
#       -> HDR(HLG/PQ) 素材先转 SDR 再套 LUT
# =============================================================================
set -uo pipefail

# ----------------------------- 可调参数 --------------------------------------
LUT="${LUT:-./look.cube}"                 # LUT 文件：.cube / .3dl / .dat / .m3d
INDIR="${INDIR:-./input}"                 # 输入目录（递归扫描子目录）
OUTDIR="${OUTDIR:-./output}"              # 输出目录（保持相对目录结构）
SUFFIX="${SUFFIX:-_graded}"               # 输出文件名后缀
VQ="${VQ:-55}"                            # 画质 1-100，越大越好（40 中等 / 55 好 / 65 高）
PIXFMT="${PIXFMT:-p010le}"                # 10-bit 像素格式，抑制调色后断层
JOBS="${JOBS:-2}"                         # 并行数（Apple Silicon 上 2-3 比较稳，再高内存带宽吃不消）
INTERP="${INTERP:-tetrahedral}"           # 插值方式：tetrahedral（默认，质量最好）
OVERWRITE="${OVERWRITE:-0}"               # 1 = 覆盖已存在的输出
VF_PRE="${VF_PRE:-}"                      # 前置滤镜链（HDR 转 SDR、去噪等）
EXTS="${EXTS:-mp4 mov MP4 MOV mkv MKV m4v M4V MXF mxf avi AVI}"  # 处理的扩展名

INDIR="${INDIR%/}"
OUTDIR="${OUTDIR%/}"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# ----------------------------- 单个文件处理 ----------------------------------
process_one() {
  local in="$1"
  local rel="${in#"$INDIR"/}"
  local stem="${rel%.*}"
  local ext="${in##*.}"
  local out="$OUTDIR/${stem}${SUFFIX}.${ext}"

  mkdir -p "$(dirname "$out")"

  if [[ -f "$out" && "$OVERWRITE" != "1" ]]; then
    printf '跳过(已存在)  %s\n' "$rel"
    return 0
  fi

  local vf
  if [[ -n "$VF_PRE" ]]; then
    vf="${VF_PRE},lut3d=file=${LUT}:interp=${INTERP}"
  else
    vf="lut3d=file=${LUT}:interp=${INTERP}"
  fi

  printf '>>> %s\n' "$rel"
  if ffmpeg -hide_banner -loglevel error -stats -y \
      -i "$in" \
      -vf "$vf" \
      -c:v hevc_videotoolbox -q:v "$VQ" -tag:v hvc1 -pix_fmt "$PIXFMT" \
      -c:a copy \
      "$out"; then
    printf 'OK    %s\n' "$out"
  else
    printf '失败  %s（音频容器不兼容时，把 -c:a copy 换成 -c:a aac -b:a 192k 重试）\n' "$rel"
    return 1
  fi
}

# ----------------------------- worker 模式 -----------------------------------
if [[ "${1:-}" == "--worker" ]]; then
  process_one "${2:?缺少输入文件}"
  exit $?
fi

# ----------------------------- 前置检查 --------------------------------------
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,26p' "$SELF"
  exit 0
fi

command -v ffmpeg >/dev/null 2>&1 || { echo "错误：未找到 ffmpeg，请先执行  brew install ffmpeg"; exit 1; }
[[ -f "$LUT" ]] || { echo "错误：LUT 文件不存在 -> $LUT"; exit 1; }
[[ -d "$INDIR" ]] || { echo "错误：输入目录不存在 -> $INDIR"; exit 1; }
mkdir -p "$OUTDIR"

echo "LUT      : $LUT"
echo "输入     : $INDIR"
echo "输出     : $OUTDIR"
echo "编码     : hevc_videotoolbox  q:v=$VQ  pix_fmt=$PIXFMT"
echo "并行     : $JOBS"
echo "-------------------------------------------------------------"

# ----------------------------- 收集文件 --------------------------------------
ext_expr=()
first=1
for e in $EXTS; do
  if [[ $first -eq 1 ]]; then
    ext_expr+=(-iname "*.${e}")
    first=0
  else
    ext_expr+=(-o -iname "*.${e}")
  fi
done

# 导出给 worker 进程
export LUT INDIR OUTDIR SUFFIX VQ PIXFMT INTERP OVERWRITE VF_PRE

find "$INDIR" -type f \( "${ext_expr[@]}" \) -print0 \
  | xargs -0 -P "$JOBS" -n 1 bash "$SELF" --worker

echo "-------------------------------------------------------------"
echo "全部完成，结果在 $OUTDIR"
