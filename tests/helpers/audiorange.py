#!/usr/bin/env python3
"""测试用的音频探针。只依赖标准库（wave / array / math），任何 python3 都能跑。

两个子命令：

  range <参考wav> <输出wav> <起点秒> [终点秒]
      把「工具提取出来的那一段」与「整段参考解码里对应的那一段」逐样本对齐：

        rate=48000 ch=1 expect=48000 got=48000 offset=0 mad=0.000 maxdiff=0 shift_mad=3314.118

      expect / got   应有的样本数与实际拿到的样本数（这条能抓住时长错）
      offset         最佳对齐偏移（样本数）= 产物的起点比请求的起点差了多少
      mad            对齐之后逐样本的平均绝对差（16bit 满量程 32767）
      maxdiff        对齐之后单样本最大差
      shift_mad      故意把产物错开半个标尺段再比的平均绝对差 —— 素材每段换一个
                     音高，所以这一项必须很大；它是「上面那个 mad≈0 不是碰巧」的反证

      参考与产物都出自同一次解码，所以无损产物正确提取时 mad 应当接近 0（只剩浮点转
      整数的取整噪声，实测不超过 1 个 LSB）。这条比对只对无损产物成立：有损产物先被编码器
      改写了一遍样本，mad 必然很大，且编码器 priming 会让 offset 偏离零（实测在一个 AAC 帧
      1024 样本以内）。有损产物改用下面的 tone 判定。

  tone <wav> <时刻秒> [窗口秒]
      用 Goertzel 算法量出该时刻的主音高，在 300..1200Hz 十个候选里取最强的一个：

        hz=500 ratio=24500.7 best_db=60.2 second_hz=400 second_db=-27.6

      素材每 BAND 秒换一个音高（见 mkfixtures.sh），所以「输出某时刻应当是什么音」
      是一条可以精确断言的条件，不依赖参考文件。
"""

import array
import atexit
import os
import math
import operator
import subprocess
import sys
import tempfile
import wave

# 与 mkfixtures.sh 里的音高标尺保持一致
TONE_BASE_HZ = 300
TONE_STEP_HZ = 100
TONE_COUNT = 10

FFMPEG = os.environ.get("FFMPEG") or "/opt/homebrew/bin/ffmpeg"

_TEMPS = []


def _cleanup():
    for p in _TEMPS:
        try:
            os.unlink(p)
        except OSError:
            pass


atexit.register(_cleanup)


def _decode_to_wav(path):
    """不是 wav 就先交给 ffmpeg 解成 16bit PCM。采样率与声道数原样保留。"""
    fd, tmp = tempfile.mkstemp(prefix="audiorange-", suffix=".wav")
    os.close(fd)
    _TEMPS.append(tmp)
    r = subprocess.run([FFMPEG, "-v", "error", "-y", "-i", path,
                        "-c:a", "pcm_s16le", tmp], capture_output=True, check=False)
    if r.returncode != 0:
        raise ValueError("ffmpeg 解码失败: %s" % r.stderr.decode(errors="replace").strip()[:200])
    return tmp


def read_wav(path):
    with open(path, "rb") as fh:
        head = fh.read(4)
    real = path if head == b"RIFF" else _decode_to_wav(path)
    with wave.open(real, "rb") as w:
        if w.getsampwidth() != 2:
            raise ValueError("只处理 16bit PCM，%s 是 %d 字节/样本" % (path, w.getsampwidth()))
        data = w.readframes(w.getnframes())
        return w.getframerate(), w.getnchannels(), data


def sad(a, b):
    """两个等长序列的绝对差之和。map/sum 都是 C 实现，比手写循环快得多。"""
    return sum(map(abs, map(operator.sub, a, b)))


def cmd_range(argv):
    window = 0.06
    while len(argv) >= 2 and argv[0] == "--window":
        window = float(argv[1])
        argv = argv[2:]
    if len(argv) not in (3, 4):
        print(__doc__, file=sys.stderr)
        return 2

    ref_path, out_path, start_sec = argv[0], argv[1], float(argv[2])
    end_sec = float(argv[3]) if len(argv) == 4 else None

    try:
        r_rate, r_ch, ref_bytes = read_wav(ref_path)
        o_rate, o_ch, out_bytes = read_wav(out_path)
    except Exception as exc:
        print("读取失败: %s" % exc, file=sys.stderr)
        return 1

    if (r_rate, r_ch) != (o_rate, o_ch):
        print("采样规格不一致: 参考 %dHz/%dch，产物 %dHz/%dch" % (r_rate, r_ch, o_rate, o_ch),
              file=sys.stderr)
        return 1

    ref = array.array("h")
    ref.frombytes(ref_bytes)
    out = array.array("h")
    out.frombytes(out_bytes)

    n_out = len(out) // r_ch
    expect = None if end_sec is None else int(round((end_sec - start_sec) * r_rate))
    base = int(round(start_sec * r_rate))
    win = int(window * r_rate)
    probe = min(n_out, max(256, r_rate // 50))     # 搜索只拿头 20ms 比，快且够判

    if n_out < probe:
        print("产物太短，无法比对（%d 样本）" % n_out, file=sys.stderr)
        return 1

    o_probe = out[:probe * r_ch]
    best = None
    for off in range(base - win, base + win + 1):
        if off < 0 or off + n_out > len(ref) // r_ch:
            continue
        seg = ref[off * r_ch:(off + probe) * r_ch]
        d = sad(seg, o_probe)
        if best is None or d < best[0]:
            best = (d, off)
    if best is None:
        print("rate=%d ch=%d expect=%s got=%d offset=none mad=-1 maxdiff=-1 shift_mad=-1"
              % (r_rate, r_ch, expect, n_out))
        return 1

    off = best[1]
    seg = ref[off * r_ch:(off + n_out) * r_ch]
    diff = list(map(operator.sub, seg, out))
    mad = sum(map(abs, diff)) / len(diff)
    maxdiff = max(map(abs, diff))

    # 反证：错开半个标尺段之后再比。先试往后错，越界就往前错 ——
    # 素材每段换一个音高，所以这一项必须很大。
    shift = int(round(0.5 * r_rate))
    shift_mad = -1.0
    for signed in (shift, -shift):
        shifted = off + signed
        if shifted < 0 or shifted + n_out > len(ref) // r_ch:
            continue
        seg2 = ref[shifted * r_ch:(shifted + n_out) * r_ch]
        d2 = list(map(operator.sub, seg2, out))
        shift_mad = sum(map(abs, d2)) / len(d2)
        break

    print("rate=%d ch=%d expect=%s got=%d offset=%d mad=%.3f maxdiff=%d shift_mad=%.3f"
          % (r_rate, r_ch, expect if expect is not None else "-", n_out,
             off - base, mad, maxdiff, shift_mad))
    return 0


def goertzel(samples, rate, freq):
    """单个频率上的幅度。加汉宁窗压旁瓣，免得相邻的 100Hz 干扰。"""
    n = len(samples)
    if n == 0:
        return 0.0
    w = 2.0 * math.pi * freq / rate
    c = 2.0 * math.cos(w)
    s1 = s2 = 0.0
    for i in range(n):
        win = 0.5 - 0.5 * math.cos(2.0 * math.pi * i / (n - 1 if n > 1 else 1))
        s0 = samples[i] * win + c * s1 - s2
        s2 = s1
        s1 = s0
    power = s1 * s1 + s2 * s2 - c * s1 * s2
    return math.sqrt(power if power > 0 else 0.0) / n


def cmd_tone(argv):
    if len(argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 2
    path, at = argv[0], float(argv[1])
    dur = float(argv[2]) if len(argv) == 3 else 0.2

    try:
        rate, ch, data = read_wav(path)
    except Exception as exc:
        print("读取失败: %s" % exc, file=sys.stderr)
        return 1

    frames = array.array("h")
    frames.frombytes(data)
    if ch > 1:                              # 多声道取第一声道就够判音高
        frames = frames[0::ch]

    i0 = int(round(at * rate))
    i1 = min(len(frames), i0 + int(round(dur * rate)))
    if i1 - i0 < rate // 100:
        print("窗口太短，取不到音高", file=sys.stderr)
        return 1
    seg = frames[i0:i1]

    cands = []
    for k in range(TONE_COUNT):
        f = TONE_BASE_HZ + TONE_STEP_HZ * k
        cands.append((goertzel(seg, rate, f), f))
    cands.sort(reverse=True)

    top_mag, top_hz = cands[0]
    sec_mag, sec_hz = cands[1]
    ratio = top_mag / sec_mag if sec_mag > 0 else float("inf")
    print("hz=%d ratio=%.1f best_db=%.1f second_hz=%d second_db=%.1f"
          % (top_hz, ratio,
             20.0 * math.log10(top_mag) if top_mag > 0 else -999.0,
             sec_hz,
             20.0 * math.log10(sec_mag) if sec_mag > 0 else -999.0))
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = argv[1]
    if cmd == "range":
        return cmd_range(argv[2:])
    if cmd == "tone":
        return cmd_tone(argv[2:])
    print("未知子命令: %s" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
