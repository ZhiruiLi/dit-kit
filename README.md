# DITKit

macOS 上的视频工具箱。原生 AppKit 界面 + 同一套逻辑的命令行模式，底层全部交给 `ffmpeg`。

目前有两个工具页：

| 工具页 | 做什么 |
|---|---|
| **LUT 批量套用** | 把同一个 `.cube` / `.3dl` / `.dat` / `.m3d` 套到任意数量的视频上，10-bit HEVC 硬编输出 |
| **视频裁剪** | 按时间码剪出指定区间；可选「快速流复制」或「精确重编码」，带起止帧预览 |

![LUT 批量套用页](preview/ui-dark.png)

![视频裁剪页](preview/trim-dark.png)

> 界面同时支持深色与浅色外观，跟随系统。

---

## 环境要求

- **macOS 12 或更高**
- **Xcode Command Line Tools**（只需要里面的 `clang`，**不需要装 Xcode**）
- **ffmpeg**
  ```bash
  brew install ffmpeg
  ```
  App 会依次在 `$PATH`、`/opt/homebrew/bin`、`/usr/local/bin`、`/usr/bin`、`/bin` 以及 App 包内的 `Resources/` 里找 `ffmpeg` 和 `ffprobe`。找不到时启动界面上会显红字提示。

## 构建

```bash
git clone https://github.com/ZhiruiLi/dit-kit.git
cd dit-kit
./build.sh
```

产物是 `build/DITKit.app`（约 270 KB），**双击即可运行**。`build.sh` 会顺手做一次 ad-hoc 临时签名，避免 Gatekeeper 拦。

源码里没有 Xcode 工程文件，`build.sh` 直接调 `clang` 把 `DITKit/*.m` 一次编完：

```
clang -fobjc-arc -O2 -Wall -framework Cocoa -framework UniformTypeIdentifiers -o ...
```

因为用的是通配符收集源文件，**加一个新工具页不用改构建脚本**。

---

## 图形界面

两个工具页共用同样的操作流程：

1. **拖入素材** —— 可以拖视频文件，也可以整个文件夹拖进去（递归扫描子目录）
2. **设定输出位置** —— 绝对目录，或「源文件旁边的子目录」
3. **调参数** —— 最大并发（默认 4）、命名冲突策略、编码质量
4. **点「开始」**

运行中每行任务会显示实时百分比进度，底部有总进度条和「停止 / 清空 / 在访达中显示」按钮。已生成过的产物（带输出后缀的文件）会被自动跳过，重复拖入同一文件也会去重。

设置会记住（存在 `~/Library/Preferences/local.tools.ditkit.plist`）。

---

## 命令行

App 二进制本身就是 CLI，用 `--cli` 进入：

```bash
DITKit=./build/DITKit.app/Contents/MacOS/DITKit
```

### 批量套 LUT

```bash
"$DITKit" --cli --lut <LUT文件> [选项] -- <视频...>
```

| 选项 | 说明 | 默认 |
|---|---|---|
| `--out <绝对目录>` | 输出到指定目录 | — |
| `--relative <子目录>` | 输出到每个源文件所在目录的子目录 | `graded` |
| `--jobs <N>` | 最大并发数 | `4` |
| `--conflict <skip\|overwrite\|rename>` | 命名冲突策略 | `skip` |
| `--quality <10-90>` | 编码质量，**数值越大画质越高** | `55` |
| `--suffix <后缀>` | 输出文件名后缀 | `_graded` |

```bash
# 整目录递归处理，并发 2，输出到固定目录
"$DITKit" --cli --lut ~/LUTs/SLog3_to_709.cube \
  --out ~/Movies/graded --jobs 2 -- ~/Movies/raw

# 每个源文件旁边生成 graded/ 子目录
"$DITKit" --cli --lut ~/LUTs/Warm.cube --relative graded -- a.mp4 sub/b.mp4
```

### 裁剪片段

```bash
"$DITKit" --cli --trim --start <起点> --end <终点> [选项] -- <视频...>
```

| 选项 | 说明 | 默认 |
|---|---|---|
| `--start <时间>` | 片段起点 | `00:00:00.000` |
| `--end <时间>` | 片段终点（**必填**） | — |
| `--fast` | 快速流复制，几乎是瞬时；**起点会吸附到最近的关键帧** | ✅ 默认 |
| `--exact` | 精确重编码，切点准确到帧 | — |
| `--quality <10-90>` | `--exact` 模式下的编码质量 | `55` |
| `--out <绝对目录>` | 输出到指定目录 | — |
| `--relative <子目录>` | 输出到每个源文件所在目录的子目录 | `trimmed` |
| `--jobs <N>` | 最大并发数 | `4` |
| `--conflict <skip\|overwrite\|rename>` | 命名冲突策略 | `skip` |
| `--suffix <后缀>` | 输出文件名后缀 | `_trim` |

**时间码写法**（下面这些都能用）：

```
00:01:30.500    时:分:秒.毫秒
01:30           分:秒
90              纯秒数
90s  / 1m30s / 1h30m
```

```bash
# 剪 10s~30s，快速流复制，批量处理
"$DITKit" --cli --trim --start 10 --end 30 --fast --out ~/out -- *.mp4

# 剪 1m30s~2m，精确重编码，高质量
"$DITKit" --cli --trim --start 1m30s --end 2m --exact --quality 75 --out ~/out -- clip.mov
```

### 退出码

| 码 | 含义 |
|---|---|
| `0` | 全部成功（含被跳过、未覆盖的） |
| `1` | 有任务失败，或引擎起不来（例如找不到 ffmpeg） |
| `2` | 参数/用法错误，或没找到可处理的视频文件 |

`--help` 打印完整用法。

---

## 项目结构

```
dit-kit/
├── DITKit/                 源码
│   ├── main.m              入口：窗口骨架（标题 / ffmpeg 状态 / 工具页切换），以及 --cli 分发
│   ├── DITUI.{h,m}         共享 UI 零件：拖放区、任务表格、操作栏、布局容器、工具页协议
│   ├── Engine.{h,m}        与工具无关的调度引擎：并发、进度解析、冲突策略、工具查找、时间码解析
│   ├── PageLUT.{h,m}       LUT 批量套用页（GUI + CLI）
│   ├── PageTrim.{h,m}      视频裁剪页（GUI + CLI）
│   └── Info.plist
├── apply-lut.sh            独立的纯 shell 批量套 LUT 脚本，不依赖 App
├── build.sh                编译打包
├── render-preview.sh       渲染 preview/ 下的界面截图
└── preview/                界面截图
```

### 设计要点

- **GUI 与 CLI 共用同一份 ffmpeg 参数构造代码。** 每个页面把参数生成抽成一个纯函数（`DITLUTArguments()` / `DITTrimArguments()`），GUI 和 `--cli` 都调它，所以两条路径的行为不会漂移。
- **`main.m` 只负责窗口骨架。** 所有工具页都常驻在页容器里，切换时用 `hidden` 显隐 —— 这样切页不会丢掉各自已拖入的素材和参数。
- **`DITEngine` 不认识任何具体工具。** 它靠一个 `DITArgsBuilder` 闭包拿到 ffmpeg 参数，另外可选地提供 `preflight`（前置校验）和 `expectedDuration`（预期输出时长，用于算进度 —— 裁剪页就是靠它把进度基准从「源时长」换成「片段时长」）。

### 加一个新工具页

1. 写一对 `PageXxx.h/.m`，实现 `DITToolPage` 协议，提供 `view`、`pageTitle`、`layoutInBounds:`、`busy`；
2. 在 `main.m` 的 `_pages` 数组里挂上 `[[PageXxx alloc] init]`；
3. 如果需要在 `--cli` 下也能用，再加一个 `+runCLI:` 和 `+cliUsage`，并在 `RunCLI()` 里分发。

构建脚本不用动。

---

## apply-lut.sh

不想用 App 的纯命令行替代方案，只有 shell + ffmpeg：

```bash
mkdir -p input output
cp ~/LUTs/Look.cube ./look.cube
cp <你的视频> input/
bash apply-lut.sh
```

用环境变量调参：

```bash
LUT=./SLog3_to_709.cube bash apply-lut.sh          # 指定 LUT
INDIR=~/Movies/log OUTDIR=~/Movies/graded bash apply-lut.sh
JOBS=3 bash apply-lut.sh                           # 并行 3 个文件
VQ=65 bash apply-lut.sh                            # 画质拉高
OVERWRITE=1 bash apply-lut.sh                      # 覆盖已有输出
# HDR(HLG/PQ) 素材先转 SDR 再套 LUT：
VF_PRE='zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=p=bt709:t=bt709:m=bt709' bash apply-lut.sh
```

它支持 `.cube / .3dl / .dat / .m3d`，递归扫描子目录并保持相对目录结构，输出的像素格式是 `p010le`（10-bit，抑制调色后的断层）。

---

## 已知限制

- **不内置 ffmpeg**，必须自己装。App 只是调度它。
- **只处理这些扩展名**：`mp4` `mov` `m4v` `mkv` `avi` `mxf` `mp4v` `hevc` `ts`（大小写不敏感）。
- **`--fast` 的切点受关键帧限制**。流复制不解码画面，起点只能落在最近的关键帧上，所以实际片段可能比请求的略长或略短。要精确到帧就用 `--exact`。
- **视频编码默认走 VideoToolbox 硬编**（`hevc_videotoolbox`）。Apple Silicon 上最快；Intel Mac 上取决于该机型 GPU 的 VideoToolbox 支持情况。
- **仅限 macOS**，用了 AppKit。
- 裁剪的 `--exact` 模式音频会重编码为 AAC 192k（切点通常不落在音频帧边界上，必须重编才能对齐）；`--fast` 模式则原样复制音频。

## License

[MIT](LICENSE)
