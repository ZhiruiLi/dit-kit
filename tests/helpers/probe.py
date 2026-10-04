#!/usr/bin/env python3
"""测试用的像素探针。只依赖标准库，任何 python3 都能跑。

五个子命令：

  frame   <视频> <时刻>                 取该时刻一帧的均值 RGB，输出 "R G B"
  region  <视频> <时刻> <x> <y> <宽> <高>  取该帧某个矩形区域的平均 RGB，输出 "R G B"
                                        （用来断言「图片铺在哪里」：整画面拉了、居中了、
                                          还是只盖住了右下角）
  nearest <视频> <时刻> <colors.tsv>    在标尺调色板里找最接近的颜色，
                                        输出 "序号 R G B 距离"
  band    <图片> <y0> <y1>              判断图片的 [y0,y1) 像素行区间里有没有内容，
                                        输出 "content" 或 "blank"
  uniform <图片>                        整张图是否只有一个颜色，输出 "uniform" 或 "varied"
                                        （用来区分「窗口合成拿不到，抓图全黑」这种
                                          环境限制，与「界面真的画错了」）

frame 与 region 都是缩到 1x1 再读原始 RGB，所以对纯色区域得到的就是精确均值；
参数里带时刻，图片文件同样能用（把时刻写 0）。
"""

import os
import subprocess
import sys

FFMPEG = os.environ.get("FFMPEG") or "/opt/homebrew/bin/ffmpeg"


def run(args):
    return subprocess.run(args, capture_output=True, check=False)


def frame_rgb(video, ts):
    """取一帧缩到 1x1 再读原始 RGB。对纯色/整段同色的画面，均值是精确的。"""
    r = run([
        FFMPEG, "-v", "error", "-ss", str(ts), "-i", video,
        "-frames:v", "1", "-vf", "scale=1:1",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-",
    ])
    if len(r.stdout) < 3:
        return None
    return tuple(r.stdout[:3])


def region_rgb(path, ts, x, y, w, h):
    """取一帧里某个矩形区域的平均 RGB。先 crop 再缩到 1x1，得到的就是该区域均值。

    这是断言「图片铺在哪里」的手段：整画面都拉满、还是只盖住中间或右下角，
    不同区域的读数会明显不同。
    """
    r = run([
        FFMPEG, "-v", "error", "-ss", str(ts), "-i", path,
        "-frames:v", "1",
        "-vf", "crop=%d:%d:%d:%d,scale=1:1" % (w, h, x, y),
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-",
    ])
    if len(r.stdout) < 3:
        return None
    return tuple(r.stdout[:3])


def read_palette(path):
    """colors.tsv: 序号<TAB>R<TAB>G<TAB>B"""
    out = []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            parts = line.split()
            out.append((int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3])))
    return out


def nearest(video, ts, palette_path):
    rgb = frame_rgb(video, ts)
    if rgb is None:
        return None
    palette = read_palette(palette_path)
    best = None
    for idx, r, g, b in palette:
        d = abs(rgb[0] - r) + abs(rgb[1] - g) + abs(rgb[2] - b)
        if best is None or d < best[0]:
            best = (d, idx, (r, g, b))
    return best, rgb


def image_rgb24(png):
    """解码成 RGB24 原始像素，返回 (宽, 高, 字节)。失败返回 (0, 0, b"")"""
    probe = run([
        FFMPEG.replace("ffmpeg", "ffprobe"), "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=width,height", "-of", "csv=p=0", png,
    ])
    try:
        w, h = (int(x) for x in probe.stdout.decode().strip().split(",")[:2])
    except Exception:
        return 0, 0, b""
    r = run([FFMPEG, "-v", "error", "-i", png, "-pix_fmt", "rgb24", "-f", "rawvideo", "-"])
    data = r.stdout
    if len(data) < w * h * 3:
        return 0, 0, b""
    return w, h, data


def band_content(png, y0, y1):
    """逐行看亮度跨度。父视图全量重绘把子控件擦掉那类 bug（顶栏空白），
    会表现为整片 blank。"""
    w, h, data = image_rgb24(png)
    if w == 0:
        return "unknown", 0, 0
    y0 = max(0, min(h, int(y0)))
    y1 = max(0, min(h, int(y1)))
    for y in range(y0, y1):
        row = data[y * w * 3:(y + 1) * w * 3]
        if row and (max(row) - min(row)) > 25:
            return "content", w, h
    return "blank", w, h


def image_uniform(png):
    """整张图是否只有一个颜色。隔行抽稀采样就够，反正只关心「有没有任何内容」。"""
    w, h, data = image_rgb24(png)
    if w == 0:
        return "unknown", 0, 0
    for y in range(0, h, 7):
        row = data[y * w * 3:(y + 1) * w * 3]
        if max(row) - min(row) > 12:
            return "varied", w, h
    return "uniform", w, h


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = argv[1]

    if cmd == "frame":
        rgb = frame_rgb(argv[2], argv[3])
        if rgb is None:
            print("读取失败", file=sys.stderr)
            return 1
        print("%d %d %d" % rgb)
        return 0

    if cmd == "region":
        if len(argv) < 8:
            print(__doc__, file=sys.stderr)
            return 2
        rgb = region_rgb(argv[2], argv[3], *(int(v) for v in argv[4:8]))
        if rgb is None:
            print("读取失败", file=sys.stderr)
            return 1
        print("%d %d %d" % rgb)
        return 0

    if cmd == "nearest":
        res = nearest(argv[2], argv[3], argv[4])
        if res is None:
            print("读取失败", file=sys.stderr)
            return 1
        (dist, idx, _), rgb = res
        print("%d %d %d %d %d" % (idx, rgb[0], rgb[1], rgb[2], dist))
        return 0

    if cmd == "band":
        state, w, h = band_content(argv[2], argv[3], argv[4])
        print(state)
        if state == "unknown":
            print("图片尺寸读取失败 (%dx%d)" % (w, h), file=sys.stderr)
            return 1
        return 0

    if cmd == "uniform":
        state, w, h = image_uniform(argv[2])
        print(state)
        if state == "unknown":
            print("图片尺寸读取失败 (%dx%d)" % (w, h), file=sys.stderr)
            return 1
        return 0

    print("未知子命令: %s" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
