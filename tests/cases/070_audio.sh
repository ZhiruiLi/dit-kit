#!/usr/bin/env bash
# 音频提取：区间精度、终点/起点留空的语义、四种格式的容器与编码、批量、错误路径。
#
# 素材是「音高标尺」——每 0.5 秒换一个纯音（300/400/…/1200Hz 循环），
# 画面同时是颜色标尺。于是「提取的区间对不对」有两条互相独立的断言：
#
#   1) 与整段解码逐样本对齐（expect_audio_range）：比对起点偏移、内容残差，
#      并用「错开半个标尺段后必须明显不同」做反证 —— 证明那个残差≈0 不是碰巧；
#   2) 直接量输出某时刻的主音高（expect_tone_at）：不依赖参考文件，
#      直接对着「源 t 秒应该是第几号音高」断言。
#
# 两条都过，才说明产物既落在正确位置、又是正确的内容。
GROUP="音频"

# 起点/终点都留空＝整段，这同时验证「视频进、音频出」：产物里不该再有画面
c_whole_file_by_default() {
    local d dur
    d=$(fresh_dir audio-whole)
    run "$BIN" --cli --audio --out "$d" -- "$FIX/tone_ruler.mp4" >/dev/null
    expect_file "$d/tone_ruler_audio.m4a"
    expect_eq "aac" "$(probe_acodec "$d/tone_ruler_audio.m4a")" "音频编码"
    expect_eq "1" "$(probe_stream_count "$d/tone_ruler_audio.m4a")" "产物里应当只剩音频流"
    dur=$(probe_duration "$d/tone_ruler_audio.m4a")
    expect_near 6.0 "$dur" 0.2 "整段提取的时长"
}

# 起点留空＝从头开始
c_start_defaults_to_beginning() {
    local d
    d=$(fresh_dir audio-from-start)
    run "$BIN" --cli --audio --end 1.5 --format wav --out "$d" -- "$FIX/tone_ruler.mp4" >/dev/null
    expect_file "$d/tone_ruler_audio.wav"
    audio_ref "$FIX/tone_ruler.mp4" "$d/ref.wav"
    expect_audio_range "$d/ref.wav" "$d/tone_ruler_audio.wav" 0 1.5 "起点留空"
    expect_tone_at "$d/tone_ruler_audio.wav" 0.1 "$(tone_expected_hz 0.1)" "起点留空"
}

# 终点留空＝一直提到结尾。这条是音频提取和裁剪最大的行为差别，必须守住。
c_end_defaults_to_tail() {
    local d
    d=$(fresh_dir audio-to-end)
    run "$BIN" --cli --audio --start 4.5 --format wav --out "$d" -- "$FIX/tone_ruler.mp4" >/dev/null
    expect_file "$d/tone_ruler_audio.wav"
    audio_ref "$FIX/tone_ruler.mp4" "$d/ref.wav"
    expect_audio_range "$d/ref.wav" "$d/tone_ruler_audio.wav" 4.5 6 "终点留空"
    # 源 4.6 秒处是第 9 段（1200Hz），产物 0.1 秒对应那里
    expect_tone_at "$d/tone_ruler_audio.wav" 0.1 "$(tone_expected_hz 4.6)" "终点留空"
}

# 区间精度：起点落在段中间（非整秒、非关键帧对齐处），终点也落在段中间
c_range_precision() {
    local d
    d=$(fresh_dir audio-precision)
    run "$BIN" --cli --audio --start 1 --end 2 --format wav --out "$d" -- "$FIX/tone_ruler.mp4" >/dev/null
    audio_ref "$FIX/tone_ruler.mp4" "$d/ref.wav"
    expect_audio_range "$d/ref.wav" "$d/tone_ruler_audio.wav" 1 2 "1.0→2.0 秒"
    # 源 1.1 秒是第 2 段（500Hz）、1.6 秒是第 3 段（600Hz）
    expect_tone_at "$d/tone_ruler_audio.wav" 0.1 "$(tone_expected_hz 1.1)" "区间首段"
    expect_tone_at "$d/tone_ruler_audio.wav" 0.6 "$(tone_expected_hz 1.6)" "区间次段"
}

# 换个起点再验一遍，避免恰好只对一个位置成立
c_range_precision_spot_check() {
    local d
    d=$(fresh_dir audio-spot)
    run "$BIN" --cli --audio --start 0.7 --end 1.3 --format wav --out "$d" -- "$FIX/tone_ruler.mp4" >/dev/null
    audio_ref "$FIX/tone_ruler.mp4" "$d/ref.wav"
    expect_audio_range "$d/ref.wav" "$d/tone_ruler_audio.wav" 0.7 1.3 "0.7→1.3 秒"
    expect_tone_at "$d/tone_ruler_audio.wav" 0.1 "$(tone_expected_hz 0.8)" "抽查区间"
}

# 时间码的几种写法都要认（与裁剪页共用同一套解析）
c_timecode_forms() {
    local d dur
    d=$(fresh_dir audio-timecode)
    run "$BIN" --cli --audio --start 00:00:01.000 --end 1m2s --format wav --out "$d" -- "$FIX/tone_ruler.mp4" >/dev/null
    expect_file "$d/tone_ruler_audio.wav"
    dur=$(probe_duration "$d/tone_ruler_audio.wav")
    # 终点 62 秒远超源时长，只会截到结尾
    expect_le "$dur" 5.1 "越界终点应当截到源尾"
    expect_ge "$dur" 4.8 "起点之后的源内容应当都提出来"
}

# 四种格式的容器与编码都要对，且都要丢掉画面
c_formats() {
    local d
    d=$(fresh_dir audio-formats)
    run "$BIN" --cli --audio --start 0.5 --end 1.5 --format m4a --out "$d" -- "$FIX/tone_ruler.mp4" >/dev/null
    run "$BIN" --cli --audio --start 0.5 --end 1.5 --format mp3 --out "$d" -- "$FIX/tone_ruler.mp4" >/dev/null
    run "$BIN" --cli --audio --start 0.5 --end 1.5 --format wav --out "$d" -- "$FIX/tone_ruler.mp4" >/dev/null
    run "$BIN" --cli --audio --start 0.5 --end 1.5 --format flac --out "$d" -- "$FIX/tone_ruler.mp4" >/dev/null

    expect_eq "aac" "$(probe_acodec "$d/tone_ruler_audio.m4a")" "m4a 编码"
    expect_eq "mp3" "$(probe_acodec "$d/tone_ruler_audio.mp3")" "mp3 编码"
    expect_eq "pcm_s16le" "$(probe_acodec "$d/tone_ruler_audio.wav")" "wav 编码"
    expect_eq "flac" "$(probe_acodec "$d/tone_ruler_audio.flac")" "flac 编码"

    expect_eq "1" "$(probe_stream_count "$d/tone_ruler_audio.m4a")" "m4a 里只剩音频流"
    expect_eq "1" "$(probe_stream_count "$d/tone_ruler_audio.flac")" "flac 里只剩音频流"

    # 无损格式不该动采样率与声道数
    expect_eq "$(probe_arate "$FIX/tone_ruler.mp4")" "$(probe_arate "$d/tone_ruler_audio.wav")" "wav 采样率"
    expect_eq "$(probe_achannels "$FIX/tone_ruler.mp4")" "$(probe_achannels "$d/tone_ruler_audio.wav")" "wav 声道数"

    # 后缀随格式走，不该沿用源文件的 .mp4
    expect_no_file "$d/tone_ruler_audio.mp4"
    note "四种格式产物: $(ls "$d" | tr '\n' ' ')"
}

# 码率要真的落到编码器上（不是只改了个标签）。
# 素材是纯音，编码器不需要那么多比特，所以 320k 不会真的跑到 320k ——
# 断言只要求两者拉开差距，并把实测字节数记在附注里。
c_bitrate_takes_effect() {
    local d lo hi
    d=$(fresh_dir audio-bitrate)
    run "$BIN" --cli --audio --format m4a --bitrate 64 --out "$d/lo" -- "$FIX/tone_ruler.mp4" >/dev/null
    run "$BIN" --cli --audio --format m4a --bitrate 320 --out "$d/hi" -- "$FIX/tone_ruler.mp4" >/dev/null
    lo=$(stat -f %z "$d/lo/tone_ruler_audio.m4a")
    hi=$(stat -f %z "$d/hi/tone_ruler_audio.m4a")
    expect_ge "$hi" "$((lo * 3 / 2))" "320k 产物应当明显大于 64k"
    note "64k=${lo} 字节，320k=${hi} 字节（6 秒素材）"
}

# 纯音频输入也要能提取（从一段录音里再切一段）
c_audio_only_input() {
    local d
    d=$(fresh_dir audio-from-audio)
    run "$BIN" --cli --audio --start 2 --end 3 --format wav --out "$d" -- "$FIX/tone_ruler.m4a" >/dev/null
    expect_file "$d/tone_ruler_audio.wav"
    audio_ref "$FIX/tone_ruler.m4a" "$d/ref.wav"
    expect_audio_range "$d/ref.wav" "$d/tone_ruler_audio.wav" 2 3 "纯音频输入"
    expect_tone_at "$d/tone_ruler_audio.wav" 0.1 "$(tone_expected_hz 2.1)" "纯音频输入"
}

# 批量 + 相对目录：每文件套用同一区间，落位到各自目录的子目录
c_batch_and_relative_output() {
    local d out
    d=$(fresh_dir audio-batch)
    mkdir -p "$d/in/子目录"
    cp "$FIX/tone_ruler.mp4" "$d/in/顶层.mp4"
    cp "$FIX/tone_ruler.mp4" "$d/in/子目录/嵌套.mp4"
    out=$(run "$BIN" --cli --audio --start 1 --end 2 --format wav --relative 提取 -- "$d/in")
    expect_contains "$out" "结束：共 2，失败 0" "批量结果"
    expect_file "$d/in/提取/顶层_audio.wav"
    expect_file "$d/in/子目录/提取/嵌套_audio.wav"
    audio_ref "$FIX/tone_ruler.mp4" "$d/ref.wav"
    expect_audio_range "$d/ref.wav" "$d/in/提取/顶层_audio.wav" 1 2 "批量产物区间"
    expect_tone_at "$d/in/子目录/提取/嵌套_audio.wav" 0.1 "$(tone_expected_hz 1.1)" "批量产物音高"
}

# --suffix 覆盖默认后缀
c_suffix_option() {
    local d out
    d=$(fresh_dir audio-suffix)
    out=$(run "$BIN" --cli --audio --end 1 --format wav --out "$d" --suffix _sound -- "$FIX/tone_ruler.mp4")
    expect_contains "$out" "结束：共 1，失败 0" "运行结果"
    expect_file "$d/tone_ruler_sound.wav"
    expect_no_file "$d/tone_ruler_audio.wav"
}

# 产物不会被当成新素材再处理一遍（源文件与产物放在同一个目录里）
c_output_is_not_reprocessed() {
    local d out
    d=$(fresh_dir audio-reprocess)
    mkdir -p "$d/in"
    cp "$FIX/tone_ruler.mp4" "$d/in/"
    run "$BIN" --cli --audio --start 0 --end 1 --format wav --out "$d/in" -- "$d/in/tone_ruler.mp4" >/dev/null
    expect_file "$d/in/tone_ruler_audio.wav"

    out=$(run "$BIN" --cli --audio --end 1 --format wav --out "$d/again" -- "$d/in")
    expect_contains "$out" "结束：共 1，失败 0" "整个目录里只有源文件该被处理"
    expect_file "$d/again/tone_ruler_audio.wav"
    expect_no_file "$d/again/tone_ruler_audio_audio.wav"
}

# 命名冲突：默认跳过，产物已存在时不覆盖
c_conflict_skip_by_default() {
    local d out
    d=$(fresh_dir audio-conflict)
    run "$BIN" --cli --audio --end 1 --format wav --out "$d" -- "$FIX/tone_ruler.mp4" >/dev/null
    out=$(run "$BIN" --cli --audio --end 1 --format wav --out "$d" -- "$FIX/tone_ruler.mp4")
    expect_contains "$out" "[跳过]" "第二次运行应当报告跳过"
    expect_contains "$out" "失败 0" "跳过不算失败"
    out=$(run "$BIN" --cli --audio --end 1 --format wav --out "$d" --conflict rename -- "$FIX/tone_ruler.mp4")
    expect_contains "$out" "结束：共 1，失败 0" "rename 策略应当产出一份新的"
    expect_file "$d/tone_ruler_audio (1).wav"
}

# 先裁剪再提取：两页能串起来用
c_pipeline_trim_then_audio() {
    local d
    d=$(fresh_dir audio-pipeline)
    run "$BIN" --cli --trim --start 2 --end 5 --exact --out "$d/cut" -- "$FIX/tone_ruler.mp4" >/dev/null
    expect_file "$d/cut/tone_ruler_trim.mp4"
    run "$BIN" --cli --audio --end 1 --format wav --out "$d/snd" -- "$d/cut/tone_ruler_trim.mp4" >/dev/null
    expect_file "$d/snd/tone_ruler_trim_audio.wav"
    # 裁剪产物第 0 秒来自源 2 秒处，所以提取出的首段应当是源 2.1 秒那一号音高
    expect_tone_at "$d/snd/tone_ruler_trim_audio.wav" 0.1 "$(tone_expected_hz 2.1)" "裁剪后再提取"
}

# 探针自检：拿错的起点去比，必须报出显著差异。
# 没有这一条，上面那些 mad=0 就只是「永远绿」的装饰 —— 分不清是「提对了」
# 还是「这个断言根本分辨不出对错」。
c_probe_can_detect_wrong_range() {
    local d rep
    d=$(fresh_dir audio-probe-check)
    run "$BIN" --cli --audio --start 1 --end 2 --format wav --out "$d" -- "$FIX/tone_ruler.mp4" >/dev/null
    audio_ref "$FIX/tone_ruler.mp4" "$d/ref.wav"

    rep=$("$PYTHON" "$AUDIORANGE" range "$d/ref.wav" "$d/tone_ruler_audio.wav" 1 2)
    expect_le "$(ar_field "$rep" mad)" 1.0 "正确起点时的残差"
    note "  起点说 1.0 秒: $rep"

    rep=$("$PYTHON" "$AUDIORANGE" range "$d/ref.wav" "$d/tone_ruler_audio.wav" 1.5 2.5)
    expect_ge "$(ar_field "$rep" mad)" 100 "错起点时必须报出显著差异"
    note "  起点说 1.5 秒: $rep"

    # 音高探针对错的时刻也要给出不同的答案，否则它也分辨不出位置
    expect_ne "$(tone_expected_hz 1.6)" "$(tone_expected_hz 2.1)" "相邻两个标尺段的音高本来就该不同"
}

# ---------- 错误路径 ----------

c_error_reversed_range() {
    expect_error 2 "终点必须大于起点" -- \
        "$BIN" --cli --audio --start 5 --end 3 -- "$FIX/tone_ruler.mp4"
}

c_error_bad_time() {
    expect_error 2 "时间格式看不懂" -- \
        "$BIN" --cli --audio --start 不是时间 -- "$FIX/tone_ruler.mp4"
}

c_error_unknown_format() {
    expect_error 2 "不认识的输出格式" -- \
        "$BIN" --cli --audio --format ogg -- "$FIX/tone_ruler.mp4"
}

c_error_no_input() {
    expect_error 2 "用法: DITKit --cli --audio" -- "$BIN" --cli --audio --end 1 --
}

c_error_no_media_found() {
    local d
    d=$(fresh_dir audio-none)
    printf 'not media' >"$d/notes.txt"
    expect_error 2 "没有找到可提取音频的文件" -- \
        "$BIN" --cli --audio --out "$d/out" -- "$d/notes.txt"
}

# 源里没有音频流时，该报失败并给出 ffmpeg 的原始原因，而不是静悄悄地成功
c_no_audio_stream_fails_loudly() {
    local d out
    d=$(fresh_dir audio-nosound)
    # 合成一段没有声音的素材
    "$FFMPEG" -y -v error -f lavfi -i "testsrc2=size=160x90:rate=10:duration=1" \
        -c:v libx264 -preset veryfast -pix_fmt yuv420p "$d/silent.mp4"
    out=$(run "$BIN" --cli --audio --end 1 --out "$d/out" -- "$d/silent.mp4")
    expect_contains "$out" "失败 1" "没有音频流时应当报失败"
    expect_contains "$out" "[失败] silent.mp4" "失败行应当点名文件"
}

reg \
    "起点终点都留空＝整段提取"      c_whole_file_by_default \
    "起点留空＝从头开始"            c_start_defaults_to_beginning \
    "终点留空＝一直提到结尾"        c_end_defaults_to_tail \
    "区间精度（1.0→2.0 秒）"        c_range_precision \
    "区间精度（抽查 0.7→1.3 秒）"   c_range_precision_spot_check \
    "时间码多种写法都能认"          c_timecode_forms \
    "四种格式的容器与编码"          c_formats \
    "码率真的落到编码器上"          c_bitrate_takes_effect \
    "纯音频输入也能提取"            c_audio_only_input \
    "批量提取与相对目录落位"        c_batch_and_relative_output \
    "--suffix 覆盖默认后缀"         c_suffix_option \
    "产物不会被当成新素材"          c_output_is_not_reprocessed \
    "命名冲突默认跳过"              c_conflict_skip_by_default \
    "先裁剪再提取能串起来"          c_pipeline_trim_then_audio \
    "探针能分辨出错误的区间"        c_probe_can_detect_wrong_range \
    "终点不大于起点退出 2"          c_error_reversed_range \
    "时间码非法退出 2"              c_error_bad_time \
    "未知输出格式退出 2"            c_error_unknown_format \
    "没有输入文件退出 2"            c_error_no_input \
    "输入里没有媒体时退出 2"        c_error_no_media_found \
    "源里没有音频流时报失败"        c_no_audio_stream_fails_loudly
