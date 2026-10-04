//
//  PageMask.swift —— 工具页：图片遮罩
//
//  把一张图片铺到画面上参与合成，所有视频套用同一张图与同一套合成参数。
//  常见的用法是边框、水印、光效、颗粒、贴纸这类「整画面压一层」的活儿。
//
//  滤镜串由 DITMaskFilterComplex() 一处生成：成品、页面预览走的是同一个函数，
//  所以预览里的构图就是成品会得到的构图，不会两边各写一套慢慢走岔。
//
//  画面宽高要写成字面量 —— overlay 的 x/y 表达式与 pad 都拿不到另一路输入的尺寸，
//  所以开工前先用 ffprobe 把每个文件的画面尺寸读出来（见 DITMaskSizeCache）。
//

import AppKit
import UniformTypeIdentifiers

// MARK: - 枚举

/// 图片怎么铺到画面上
enum DITMaskFit: Int, CaseIterable {
    case stretch = 0
    case cover = 1
    case contain = 2
    case original = 3

    var title: String {
        switch self {
        case .stretch:  return "拉伸铺满"
        case .cover:    return "等比铺满"
        case .contain:  return "等比完整"
        case .original: return "原始大小"
        }
    }

    var hint: String {
        switch self {
        case .stretch:  return "把图片拉成和画面一样大，比例不同会被压扁或拉长"
        case .cover:    return "保持比例铺满整个画面，超出的部分裁掉"
        case .contain:  return "保持比例完整放进画面，四周留出画面本身"
        case .original: return "不缩放，按选定的位置摆放"
        }
    }

    /// 位置只对「原始大小」有意义：另外三种都会把整个画面铺满
    var usesPosition: Bool { self == .original }

    /// 图层要接的缩放段
    ///
    /// force_original_aspect_ratio 的 increase / decrease 都是相对「目标框」而言，
    /// 比目标框小的图同样会被拉大 —— 所以这三种都是「铺到画面里」，
    /// 想保持像素 1:1 用 original。
    ///
    /// 原始大小不缩放，返回 nil
    func scaleFilter(videoW: Int, videoH: Int) -> String? {
        switch self {
        case .stretch:
            return "scale=\(videoW):\(videoH)"
        case .cover:
            return "scale=\(videoW):\(videoH):force_original_aspect_ratio=increase,crop=\(videoW):\(videoH)"
        case .contain:
            return "scale=\(videoW):\(videoH):force_original_aspect_ratio=decrease"
        case .original:
            return nil
        }
    }

    var key: String {
        switch self {
        case .stretch:  return "stretch"
        case .cover:    return "cover"
        case .contain:  return "contain"
        case .original: return "original"
        }
    }

    init?(key: String) {
        guard let f = DITMaskFit.allCases.first(where: { $0.key == key.lowercased() }) else { return nil }
        self = f
    }
}

/// 图层摆在哪里。只对「原始大小」生效
enum DITMaskPosition: Int, CaseIterable {
    case topLeft = 0
    case center = 1
    case bottomRight = 2

    var title: String {
        switch self {
        case .topLeft:     return "左上"
        case .center:      return "居中"
        case .bottomRight: return "右下"
        }
    }

    var key: String {
        switch self {
        case .topLeft:     return "tl"
        case .center:      return "center"
        case .bottomRight: return "br"
        }
    }

    init?(key: String) {
        let k = key.lowercased()
        guard let p = DITMaskPosition.allCases.first(where: { $0.key == k }) else { return nil }
        self = p
    }

    /// overlay 的 x/y 表达式。W/H 是画面，w/h 是这一层。
    func offset(fit: DITMaskFit) -> (x: String, y: String) {
        switch fit {
        case .stretch, .cover:
            // 这两种已经把画面铺满，位置无从谈起
            return ("0", "0")
        case .contain:
            // 等比完整固定居中：四周的留边是对称的
            return ("(W-w)/2", "(H-h)/2")
        case .original:
            switch self {
            case .topLeft:     return ("0", "0")
            case .center:      return ("(W-w)/2", "(H-h)/2")
            case .bottomRight: return ("W-w", "H-h")
            }
        }
    }
}

/// 图片与画面怎么合
enum DITMaskBlend: Int, CaseIterable {
    case normal = 0
    case multiply = 1
    case screen = 2

    var title: String {
        switch self {
        case .normal:   return "普通"
        case .multiply: return "正片叠底"
        case .screen:   return "滤色"
        }
    }

    var key: String {
        switch self {
        case .normal:   return "normal"
        case .multiply: return "multiply"
        case .screen:   return "screen"
        }
    }

    init?(key: String) {
        guard let b = DITMaskBlend.allCases.first(where: { $0.key == key.lowercased() }) else { return nil }
        self = b
    }

    var hint: String {
        switch self {
        case .normal:   return "按图片自己的透明通道叠上去，最常用"
        case .multiply: return "只压暗不提亮；图片不存在的地方按白色算，等于原样保留"
        case .screen:   return "只提亮不压暗；图片不存在的地方按黑色算，等于原样保留"
        }
    }

    /// 混合模式的单位元：图片铺不到的地方填上它，画面就等于没被动过。
    /// 正片叠底的单位元是白（乘 1 不变），滤色是黑（加 0 不变）。
    var neutralColor: String {
        switch self {
        case .multiply: return "white"
        case .screen:   return "black"
        case .normal:   return "black"      // 普通叠加不用画布，这个值取不到
        }
    }
}

/// 可做遮罩的图片后缀
let DITMaskImageExtensions = "png jpg jpeg webp bmp tif tiff tga heic avif"

/// 可处理的视频后缀（遮罩页的视频列表只收视频；图片走自己的拖放区）
let DITMaskInputExtensions = "mp4 mov m4v mkv avi mxf ts webm flv wmv"

/// 「.png / .jpg / …」这种给人看的写法
func DITMaskImageExtensionText() -> String {
    DITMaskImageExtensions.components(separatedBy: " ")
        .filter { !$0.isEmpty }
        .map { "." + $0 }
        .joined(separator: " / ")
}

// MARK: - 合成参数

/// 合成参数（GUI 与 --cli 共用）
final class DITMaskSpec {
    var imagePath = ""
    var fit: DITMaskFit = .stretch
    var position: DITMaskPosition = .center
    var blend: DITMaskBlend = .normal
    /// 不透明度 0..100。0 表示画面完全不受影响
    var opacity = 100
    var quality = 55
}

/// 画面尺寸的小缓存。滤镜串要写死宽高，批量时同一个文件不必反复探测。
final class DITMaskSizeCache {

    private var cache: [String: (w: Int, h: Int)] = [:]

    func size(_ path: String) -> (w: Int, h: Int)? {
        if let c = cache[path] { return c }
        guard let s = DITEngine.probeVideoSize(path) else { return nil }
        cache[path] = s
        return s
    }

    /// 开工前逐个体检。返回第一个读不出尺寸的文件的说明，都正常时返回 nil。
    /// 放在这里而不是运行中报错，是因为滤镜串必须先有尺寸才写得出来。
    func preflight(_ jobs: [DITJob]) -> String? {
        for j in jobs where size(j.inputPath) == nil {
            let name = (j.inputPath as NSString).lastPathComponent
            return "读不出画面尺寸：\(name)（文件可能损坏，或者不是 ffmpeg 认得的视频）"
        }
        return nil
    }
}

// MARK: - ffmpeg 参数

/// 合成用的滤镜串。成品与预览共用这一处。
///
/// previewWidth 不为 nil 时，最后接一段缩小 —— 预览只需要一张小图，
/// 没必要为它生成 4K 的 PNG。
func DITMaskFilterComplex(_ spec: DITMaskSpec,
                          videoW: Int, videoH: Int,
                          previewWidth: Int? = nil) -> String {
    let w = max(2, videoW)
    let h = max(2, videoH)
    let opacity = Double(max(0, min(100, spec.opacity))) / 100.0

    // 图层：先转成带 alpha 的 RGBA，再按适配方式缩放
    var layer = "[1:v]format=rgba"
    if let s = spec.fit.scaleFilter(videoW: w, videoH: h) { layer += "," + s }
    // 普通叠加用图层自己的 alpha 表达不透明度；混合方式那边交给 all_opacity
    if spec.blend == .normal && opacity < 1.0 {
        layer += String(format: ",colorchannelmixer=aa=%.4f", opacity)
    }
    layer += "[fg]"

    let off = spec.position.offset(fit: spec.fit)
    var g: String

    if spec.blend == .normal {
        g = layer + ";[0:v][fg]overlay=\(off.x):\(off.y):format=auto[vpre]"
    } else {
        // 正片叠底与滤色要在 RGB 空间算：在 YUV 的各个平面上直接相乘得到的是错颜色。
        // 而 gbrp 没有 alpha 通道，所以先把图层铺到一张「中性色」画布上 ——
        // 图片铺不到的地方填上单位元，乘/加之后画面原样保留。
        //
        // shortest=1 是必需的：中性色画布来自 lavfi 的 color，它是无限长的源，
        // 而 overlay 默认 eof_action=repeat、shortest=0 —— 结果就是永不结束，
        // ffmpeg 会一直编码下去。加上它之后这一步只产出图层那么多帧（静态图就是
        // 一帧），后面 blend 的默认 repeatlast 会把这一帧重复到与画面等长。
        g = "color=c=\(spec.blend.neutralColor):s=\(w)x\(h)[ws]"
        g += ";" + layer + ";[ws][fg]overlay=\(off.x):\(off.y):format=auto:shortest=1[flat]"
        g += ";[flat]format=gbrp[flatg];[0:v]format=gbrp[baseg]"
        g += String(format: ";[baseg][flatg]blend=all_mode=%@:all_opacity=%.4f[vpre]", spec.blend.key, opacity)
    }

    if let pw = previewWidth, pw > 0 {
        g += ";[vpre]scale=\(pw):-2[vout]"
    } else {
        g += ";[vpre]null[vout]"
    }
    return g
}

/// 合成的 ffmpeg 参数（GUI 与 --cli 共用）
func DITMaskArguments(_ job: DITJob, _ spec: DITMaskSpec, videoW: Int, videoH: Int) -> [String] {
    let image = (spec.imagePath as NSString).expandingTildeInPath
    var a: [String] = ["-i", job.inputPath, "-i", image]
    a += ["-filter_complex", DITMaskFilterComplex(spec, videoW: videoW, videoH: videoH)]
    a += ["-map", "[vout]", "-map", "0:a?"]

    a += ["-c:v", "hevc_videotoolbox",
          "-q:v", String(spec.quality),
          "-pix_fmt", "p010le"]

    let lowExt = (job.inputPath as NSString).pathExtension.lowercased()
    if lowExt == "mp4" || lowExt == "mov" || lowExt == "m4v" {
        a += ["-tag:v", "hvc1"]
    }
    a += ["-c:a", "copy"]
    return a
}

/// 预览横幅下方那行提示的常规文案（出错时会被换成别的）
private func DITMaskPreviewHint() -> String {
    "预览与成品走的是同一段滤镜串；时刻可以写 00:00:03 或 3 / 3s，留空＝取画面中间"
}

// MARK: - 工具页

final class PageMask: NSObject, DITToolPage, NSTextFieldDelegate {

    // 控件全部先建好、再在 buildControls() 里接线（target/action 与 addSubview）。
    // 这样能用 let 而不是一堆隐式解包可选值，同时在 init 里也拿得到 self。
    private let layoutView = LayoutView(frame: NSRect(x: 0, y: 0, width: 740, height: 850))

    private let sec1Label = DITSectionLabel("1 · 遮罩图片")
    private let sec2Label = DITSectionLabel("2 · 适配与合成")
    private let sec3Label = DITSectionLabel("3 · 预览")
    private let sec4Label = DITSectionLabel("4 · 输出")
    private let sec5Label = DITSectionLabel("5 · 待处理文件")

    private let imageWell = DropWellView(frame: .zero)
    private let imageHint = DITLabel("", 11, false)

    private let fitSeg = NSSegmentedControl(frame: .zero)
    private let fitHint = DITLabel("", 11, false)
    private let posSeg = NSSegmentedControl(frame: .zero)
    private let opacityLabel = DITLabel("不透明度", 12, false)
    private let opacitySlider = NSSlider(frame: .zero)
    private let opacityValue = DITLabel("100%", 12, false)
    private let blendSeg = NSSegmentedControl(frame: .zero)
    private let blendHint = DITLabel("", 11, false)

    private let previewCaption = DITLabel("", 11, false)
    private let previewTimeLabel = DITLabel("预览时刻", 12, false)
    private let previewTimeField = NSTextField(frame: .zero)
    private let previewImage = NSImageView(frame: .zero)
    private let previewHint = DITLabel(DITMaskPreviewHint(), 11, false)

    private let outModeSeg = NSSegmentedControl(frame: .zero)
    private let outField = NSTextField(frame: .zero)
    private let outChooseBtn = NSButton(frame: .zero)
    private let outHintLabel = DITLabel("", 11, false)
    private let qualityLabel = DITLabel("编码质量", 12, false)
    private let qualitySlider = NSSlider(frame: .zero)
    private let qualityValue = DITLabel("55", 12, false)
    private let qualityHint = DITLabel("越大越清晰，体积也越大", 11, false)

    private let filesCount = DITLabel("", 11, false)
    private let addFilesBtn = DITButton("添加文件…", nil, nil)
    private let removeSelBtn = DITButton("删除选中", nil, nil)
    private let jobTable = DITJobTable()
    private let actionBar = DITActionBar()

    private var engine: DITEngine?
    private var maskPath: String?
    /// 预览取样的那一个源文件（唯一选中项优先，否则第一个）
    private var srcPath: String?
    private var srcSize: (w: Int, h: Int)?
    private var lastOutputDir: String?
    /// 已点击停止、等引擎收尾；期间不让进度行覆盖提示
    private var stopping = false
    private var concurrency = 4
    private var conflictIndex = 0
    /// 防止旧的预览结果覆盖新画面
    private var previewToken = 0
    /// 预览状态：给诊断行用，也是「图真的画上去了」的凭证
    private var previewState = "—"
    /// 最近一次取帧实际用的时刻（可能被夹到素材时长之内）
    private var previewUsedTime: Double = 0
    /// 合成参数改动后延迟重画，拖滑块时不必每个像素都跑一次 ffmpeg
    private var previewTimer: Timer?

    override init() {
        super.init()
        buildControls()
        loadDefaults()
        refreshSourceInfo()    // 空列表时也要把引导语摆上
        refreshAll()
    }

    // MARK: 协议

    var view: NSView { layoutView }
    var pageTitle: String { "图片遮罩" }
    var busy: Bool { engine?.isRunning ?? false }

    func layoutInBounds(_ bounds: NSRect) {
        doLayout()
    }

    // MARK: 构建界面

    private func buildControls() {
        layoutView.onLayout = { [weak self] in self?.doLayout() }

        // 1 · 遮罩图片
        layoutView.addSubview(sec1Label)

        imageWell.caption = "把图片拖到这里"
        imageWell.hint = "或点击此处选择　·　支持 " + DITMaskImageExtensionText()
        imageWell.onPaths = { [weak self] paths in self?.setMaskFromPaths(paths) }
        imageWell.onClick = { [weak self] in self?.chooseMaskImage() }
        // 后缀名不对（比如顺手拖进来一个视频）就当场拒收，并说明原因
        imageWell.willAcceptPaths = { [weak self] paths in
            if DITFirstMaskImagePath(paths) != nil { return true }
            self?.reportRejectedImage(paths)
            return false
        }
        layoutView.addSubview(imageWell)

        imageHint.lineBreakMode = .byTruncatingMiddle
        layoutView.addSubview(imageHint)

        // 2 · 适配与合成
        layoutView.addSubview(sec2Label)

        fitSeg.segmentCount = DITMaskFit.allCases.count
        for f in DITMaskFit.allCases {
            fitSeg.setLabel(f.title, forSegment: f.rawValue)
        }
        fitSeg.selectedSegment = DITMaskFit.stretch.rawValue
        fitSeg.segmentStyle = .rounded
        fitSeg.target = self
        fitSeg.action = #selector(fitChanged)
        layoutView.addSubview(fitSeg)
        layoutView.addSubview(fitHint)

        posSeg.segmentCount = DITMaskPosition.allCases.count
        for p in DITMaskPosition.allCases {
            posSeg.setLabel(p.title, forSegment: p.rawValue)
        }
        posSeg.selectedSegment = DITMaskPosition.center.rawValue
        posSeg.segmentStyle = .rounded
        posSeg.target = self
        posSeg.action = #selector(composeChanged)
        layoutView.addSubview(posSeg)

        layoutView.addSubview(opacityLabel)

        opacitySlider.minValue = 0
        opacitySlider.maxValue = 100
        opacitySlider.doubleValue = 100
        opacitySlider.isContinuous = true
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged)
        layoutView.addSubview(opacitySlider)
        layoutView.addSubview(opacityValue)

        blendSeg.segmentCount = DITMaskBlend.allCases.count
        for b in DITMaskBlend.allCases {
            blendSeg.setLabel(b.title, forSegment: b.rawValue)
        }
        blendSeg.selectedSegment = DITMaskBlend.normal.rawValue
        blendSeg.segmentStyle = .rounded
        blendSeg.target = self
        blendSeg.action = #selector(composeChanged)
        layoutView.addSubview(blendSeg)
        layoutView.addSubview(blendHint)

        // 3 · 预览
        layoutView.addSubview(sec3Label)

        previewCaption.lineBreakMode = .byTruncatingTail
        layoutView.addSubview(previewCaption)
        layoutView.addSubview(previewTimeLabel)

        previewTimeField.placeholderString = "留空＝画面中间"
        previewTimeField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        previewTimeField.delegate = self
        previewTimeField.target = self
        previewTimeField.action = #selector(previewTimeEdited)
        layoutView.addSubview(previewTimeField)

        previewImage.imageFrameStyle = .grayBezel
        previewImage.imageScaling = .scaleProportionallyUpOrDown
        previewImage.imageAlignment = .alignCenter
        layoutView.addSubview(previewImage)

        layoutView.addSubview(previewHint)

        // 4 · 输出
        layoutView.addSubview(sec4Label)

        outModeSeg.segmentCount = 2
        outModeSeg.setLabel("相对源文件", forSegment: 0)
        outModeSeg.setLabel("绝对路径", forSegment: 1)
        outModeSeg.selectedSegment = 0
        outModeSeg.segmentStyle = .rounded
        outModeSeg.target = self
        outModeSeg.action = #selector(outModeChanged)
        layoutView.addSubview(outModeSeg)

        outField.placeholderString = "masked"
        outField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        outField.target = self
        outField.action = #selector(saveDefaults)
        layoutView.addSubview(outField)

        outChooseBtn.title = "选择…"
        outChooseBtn.bezelStyle = .rounded
        outChooseBtn.target = self
        outChooseBtn.action = #selector(chooseOutputDir)
        layoutView.addSubview(outChooseBtn)

        layoutView.addSubview(outHintLabel)
        layoutView.addSubview(qualityLabel)

        qualitySlider.minValue = 10
        qualitySlider.maxValue = 90
        qualitySlider.doubleValue = 55
        qualitySlider.isContinuous = true
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged)
        layoutView.addSubview(qualitySlider)
        layoutView.addSubview(qualityValue)
        layoutView.addSubview(qualityHint)

        // 5 · 待处理文件（列表本身就是拖入区）
        layoutView.addSubview(sec5Label)

        filesCount.alignment = .right
        layoutView.addSubview(filesCount)

        addFilesBtn.target = self
        addFilesBtn.action = #selector(chooseVideos)
        layoutView.addSubview(addFilesBtn)

        removeSelBtn.target = self
        removeSelBtn.action = #selector(deleteSelectedJobs)
        layoutView.addSubview(removeSelBtn)

        jobTable.emptyHint = "把要加遮罩的视频拖到这里"
        jobTable.emptySubHint = "支持多选、多目录与整个文件夹；所有视频套用同一张图与同一套合成参数"
        jobTable.onDropPaths = { [weak self] paths in self?.addPaths(paths) }
        jobTable.onSelectionChanged = { [weak self] in
            // 选中项决定预览哪一个，所以选中变化也要重取样
            self?.refreshSourceInfo()
            self?.refreshAll()
        }
        jobTable.onDeleteRequested = { [weak self] in self?.deleteSelectedJobs() }

        layoutView.addSubview(jobTable.scrollView)

        // 底部
        actionBar.setStartTitle("开始合成")
        actionBar.addToView(layoutView)
        actionBar.onStart = { [weak self] in self?.startCompose() }
        actionBar.onStop = { [weak self] in self?.stopCompose() }
        actionBar.onClear = { [weak self] in self?.clearJobs() }
        actionBar.onReveal = { [weak self] in self?.revealOutput() }
    }

    // MARK: 布局

    /// 文件列表的最小高度：表头加两行。比这更矮就会被裁掉半行。
    private let listMinHeight: CGFloat = 80.0

    private func doLayout() {
        if layoutView.superview == nil { return }

        // 预览和文件列表抢的是同一段竖直空间，两者高度之和是个定值。
        // 先把预览压成 0 量出总量，再按「列表先拿够最小值」切分，剩下的都给预览。
        // 版面实在太矮时预览会一路让到 0，也不会让列表溢出去压住底部操作栏。
        let budget = layoutPass(previewHeight: 0).roomForList
        let pvMax: CGFloat = 220.0
        _ = layoutPass(previewHeight: max(0, min(pvMax, budget - listMinHeight)))
    }

    /// 按给定的预览高度排一遍版，返回列表区起点与它可用到的竖直空间。
    /// 试算时会被调用两次 —— 这里只设置 frame，重复设置没有副作用。
    private func layoutPass(previewHeight pv: CGFloat) -> (listTop: CGFloat, roomForList: CGFloat) {
        let b = layoutView.bounds
        let W = b.size.width
        let H = b.size.height
        let PAD: CGFloat = 18.0
        let x = PAD
        let w = W - PAD * 2
        var y = PAD

        // 1 · 遮罩图片
        DITPlaceSection(sec1Label, &y, x, w)
        DITFrame(imageWell, x, y, w, 42)
        y += 42 + 6
        DITFrame(imageHint, x, y, w, 14)
        y += 14 + 10

        // 2 · 适配与合成（每行右边跟一句当前选项的说明，省掉一整行提示）
        DITPlaceSection(sec2Label, &y, x, w)

        DITFrame(fitSeg, x, y, 336, 24)
        DITFrame(fitHint, x + 348, y + 5, w - 348, 14)
        y += 24 + 6

        DITFrame(posSeg, x, y, 168, 24)
        DITFrame(opacityLabel, x + 184, y + 3, 62, 18)
        DITFrame(opacitySlider, x + 248, y + 1, 150, 22)
        DITFrame(opacityValue, x + 404, y + 3, 52, 18)
        y += 24 + 6

        DITFrame(blendSeg, x, y, 240, 24)
        DITFrame(blendHint, x + 252, y + 5, w - 252, 14)
        y += 24 + 10

        // 3 · 预览（说明行左边写预览的是哪个文件，右边是取帧时刻）
        DITPlaceSection(sec3Label, &y, x, w)

        let timeW: CGFloat = 112.0
        let posW: CGFloat = 60.0
        DITFrame(previewTimeLabel, x + w - timeW - posW - 8, y + 3, posW, 18)
        DITFrame(previewTimeField, x + w - timeW, y, timeW, 24)
        DITFrame(previewCaption, x, y + 3, max(80.0, w - timeW - posW - 16), 18)
        y += 24 + 6

        DITFrame(previewImage, x, y, w, pv)
        y += pv + 6
        DITFrame(previewHint, x, y, w, 14)
        y += 14 + 8

        // 4 · 输出（标题与输出方式的切换器同一行，省下竖向空间给预览）
        DITFrame(sec4Label, x, y + 4, 120, 16)
        DITFrame(outModeSeg, x + 126, y, 280, 24)
        y += 24 + 6
        let btnW: CGFloat = 88.0
        DITFrame(outField, x, y, w - btnW - 8, 24)
        DITFrame(outChooseBtn, x + w - btnW, y, btnW, 24)
        y += 24 + 4
        DITFrame(outHintLabel, x, y, w, 14)
        y += 14 + 8

        DITFrame(qualityLabel, x, y + 3, 62, 18)
        DITFrame(qualitySlider, x + 68, y + 1, 160, 22)
        DITFrame(qualityValue, x + 236, y + 3, 32, 18)
        DITFrame(qualityHint, x + 276, y + 3, w - 276, 14)
        y += 22 + 10

        // 5 · 文件清单（标题行右边放「添加文件…／删除选中」，计数贴左）
        let rh: CGFloat = 24.0
        DITFrame(sec5Label, x, y + 4, w * 0.5, 16)
        let bw2: CGFloat = 92.0, bgap: CGFloat = 8.0
        DITFrame(removeSelBtn, x + w - bw2, y, bw2, rh)
        DITFrame(addFilesBtn, x + w - bw2 * 2 - bgap, y, bw2, rh)
        DITFrame(filesCount, x + w * 0.5, y + 6, w * 0.5 - bw2 * 2 - bgap - 8, 14)
        y += rh + 8

        // 底部操作栏
        let bottom = actionBar.layoutFromBottom(H - PAD, x: x, width: w)

        jobTable.layoutColumnsForWidth(w)
        let room = bottom - y
        DITFrame(jobTable.scrollView, x, y, w, max(0, room))
        return (y, room)
    }

    // MARK: 偏好

    private func loadDefaults() {
        let d = UserDefaults.standard

        let mode = d.integer(forKey: "mask.outMode")
        outModeSeg.selectedSegment = (mode == 1) ? 1 : 0
        let outVal = d.string(forKey: "mask.outValue") ?? ""
        outField.stringValue = outVal.isEmpty ? "masked" : outVal

        var conf = d.integer(forKey: "mask.conflict")
        if conf < 0 || conf > 2 { conf = 0 }
        conflictIndex = conf

        var conc = d.integer(forKey: "mask.concurrency")
        if conc <= 0 { conc = 4 }
        concurrency = conc

        var q = d.integer(forKey: "mask.quality")
        if q <= 0 { q = 55 }
        qualitySlider.doubleValue = Double(q)
        qualityValue.stringValue = "\(q)"

        fitSeg.selectedSegment = (DITMaskFit(key: d.string(forKey: "mask.fit") ?? "") ?? .stretch).rawValue
        posSeg.selectedSegment = (DITMaskPosition(key: d.string(forKey: "mask.pos") ?? "") ?? .center).rawValue
        blendSeg.selectedSegment = (DITMaskBlend(key: d.string(forKey: "mask.blend") ?? "") ?? .normal).rawValue

        // 0 是不透明度的合法取值（画面完全不受影响），所以不能用「读出来是 0 就当成
        // 没存过」来兜底 —— 那会把默认值也压成 0。这里按「键在不在」判断。
        var op = d.object(forKey: "mask.opacity") == nil ? 100 : d.integer(forKey: "mask.opacity")
        if op < 0 || op > 100 { op = 100 }
        opacitySlider.doubleValue = Double(op)

        var img = d.string(forKey: "mask.image") ?? ""
        var t = d.string(forKey: "mask.previewTime") ?? ""

        // 自检 / 截图预览时可用环境变量注入，避免污染用户偏好
        let env = ProcessInfo.processInfo.environment
        if let v = env["DITKIT_IMAGE"] { img = v }
        if let v = env["DITKIT_OVERLAY_FIT"], let f = DITMaskFit(key: v) { fitSeg.selectedSegment = f.rawValue }
        if let v = env["DITKIT_OVERLAY_BLEND"], let b = DITMaskBlend(key: v) { blendSeg.selectedSegment = b.rawValue }
        if let v = env["DITKIT_OVERLAY_POS"], let p = DITMaskPosition(key: v) { posSeg.selectedSegment = p.rawValue }
        if let v = env["DITKIT_OVERLAY_OPACITY"] { opacitySlider.doubleValue = Double((v as NSString).integerValue) }
        if let v = env["DITKIT_OVERLAY_TIME"] { t = v }
        previewTimeField.stringValue = t

        if !img.isEmpty {
            maskPath = img
        }

        outModeChanged()
        // applyFitDisplay 里要按适配方式决定位置那一排能不能用，得先跑一次
        applyFitDisplay()
        applyBlendDisplay()
        applyImageDisplay()
    }

    @objc private func saveDefaults() {
        let d = UserDefaults.standard
        d.set(outModeSeg.selectedSegment, forKey: "mask.outMode")
        d.set(outField.stringValue, forKey: "mask.outValue")
        d.set(conflictIndex, forKey: "mask.conflict")
        d.set(concurrency, forKey: "mask.concurrency")
        d.set(Int(qualitySlider.doubleValue), forKey: "mask.quality")
        d.set(currentFit().key, forKey: "mask.fit")
        d.set(currentPosition().key, forKey: "mask.pos")
        d.set(currentBlend().key, forKey: "mask.blend")
        d.set(Int(opacitySlider.doubleValue), forKey: "mask.opacity")
        d.set(maskPath ?? "", forKey: "mask.image")
        d.set(previewTimeField.stringValue, forKey: "mask.previewTime")
    }

    // MARK: 参数取值

    private func currentFit() -> DITMaskFit {
        DITMaskFit(rawValue: fitSeg.selectedSegment) ?? .stretch
    }

    private func currentPosition() -> DITMaskPosition {
        DITMaskPosition(rawValue: posSeg.selectedSegment) ?? .center
    }

    private func currentBlend() -> DITMaskBlend {
        DITMaskBlend(rawValue: blendSeg.selectedSegment) ?? .normal
    }

    private func currentOpacity() -> Int { Int(opacitySlider.doubleValue.rounded()) }

    private func currentImagePath() -> String {
        (maskPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildSpec() -> DITMaskSpec {
        let s = DITMaskSpec()
        s.imagePath = currentImagePath()
        s.fit = currentFit()
        s.position = currentPosition()
        s.blend = currentBlend()
        s.opacity = currentOpacity()
        s.quality = Int(qualitySlider.doubleValue.rounded())
        return s
    }

    /// 取帧时刻。留空＝画面中间；写法看不懂时返回 nil。
    ///
    /// 超出素材时长时夹到结尾之前：预览是用来看大致效果的，
    /// 为了一个够不着的时刻给一张空白图，不如给最后那一帧。
    /// 实际用的时刻记在 previewUsedTime 里，诊断行回显的是它而不是用户输入。
    private func previewTime(quiet: Bool) -> Double? {
        let text = previewTimeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let dur = srcPath.map { DITEngine.probeDuration($0) } ?? 0
        let wanted: Double
        if text.isEmpty {
            wanted = dur > 0 ? dur / 2.0 : 0.5
        } else {
            let v = DITEngine.secondsFromTimeString(text)
            if v < 0 {
                if !quiet { actionBar.setStatus("预览时刻看不懂：请用 00:00:03 或 3 / 3s") }
                return nil
            }
            wanted = v
        }
        // 留一点余量：正好落在时长上的位置抽不出帧
        let ceiling = dur > 0 ? max(0, dur - 0.2) : wanted
        let used = min(max(0, wanted), ceiling)
        previewUsedTime = used
        return used
    }

    // MARK: 交互

    @objc private func outModeChanged() {
        let absolute = (outModeSeg.selectedSegment == 1)
        outChooseBtn.isEnabled = absolute
        if absolute {
            outField.placeholderString = "/Users/you/Movies/masked"
            outHintLabel.stringValue = "带 ~ 会自动展开；目录不存在会自动创建"
        } else {
            outField.placeholderString = "masked"
            outHintLabel.stringValue = "相对每个源文件所在目录；填 . 表示输出到源文件同目录"
        }
        saveDefaults()
    }

    @objc private func fitChanged() {
        applyFitDisplay()
        saveDefaults()
        schedulePreview(after: 0)
    }

    @objc private func composeChanged() {
        applyFitDisplay()
        applyBlendDisplay()
        saveDefaults()
        schedulePreview(after: 0)
    }

    @objc private func opacityChanged() {
        updateOpacityDisplay()
        saveDefaults()
        // 拖滑块时每个像素都重画一张图毫无意义，攒一下再画
        schedulePreview(after: 0.25)
    }

    @objc private func qualityChanged() {
        qualityValue.stringValue = "\(Int(qualitySlider.doubleValue.rounded()))"
        saveDefaults()
    }

    @objc func controlTextDidEndEditing(_ note: Notification) {
        previewTimeEdited()
    }

    @objc private func previewTimeEdited() {
        saveDefaults()
        schedulePreview(after: 0)
    }

    private func applyFitDisplay() {
        let fit = currentFit()
        fitHint.stringValue = fit.hint

        // 位置只对「原始大小」有意义，另外三种会把画面铺满；压暗成不可点的样子，
        // 免得那三个按钮看起来像是生效的（与音频页处理无损格式码率的方式一致）
        let usable = fit.usesPosition
        posSeg.isEnabled = usable && !(engine?.isRunning ?? false)
        fitHint.textColor = usable ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
    }

    private func applyBlendDisplay() {
        blendHint.stringValue = currentBlend().hint
        updateOpacityDisplay()
    }

    private func updateOpacityDisplay() {
        let op = currentOpacity()
        opacityValue.stringValue = "\(op)%"
        opacityValue.textColor = op == 0 ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor
    }

    // MARK: 遮罩图片

    private func applyImageDisplay() {
        let path = currentImagePath()
        guard !path.isEmpty else {
            imageWell.caption = "把图片拖到这里"
            imageWell.hint = "或点击此处选择　·　支持 " + DITMaskImageExtensionText()
            imageHint.stringValue = "还没有选择遮罩图片"
            imageHint.textColor = NSColor.tertiaryLabelColor
            refreshSourceInfo()
            schedulePreview(after: 0)
            return
        }
        imageWell.caption = (path as NSString).lastPathComponent
        imageWell.hint = path

        if let sz = DITEngine.probeVideoSize(path) {
            imageHint.stringValue = "\(path)　·　\(sz.w)×\(sz.h)"
            imageHint.textColor = NSColor.secondaryLabelColor
        } else {
            imageHint.stringValue = "读不出这张图的尺寸，可能不是有效的图片：\(path)"
            imageHint.textColor = NSColor.systemOrange
        }
        refreshSourceInfo()
        schedulePreview(after: 0)
    }

    /// 拖进来的东西里一张图都没有 —— 把第一个不合格的说出来，别让人以为拖成功了
    private func reportRejectedImage(_ paths: [String]) {
        let first = paths.first
        let name = first.map { ($0 as NSString).lastPathComponent } ?? ""
        var isDir: ObjCBool = false
        var exists = false
        if let first {
            exists = FileManager.default.fileExists(atPath: first, isDirectory: &isDir)
        }
        NSSound.beep()
        if !paths.isEmpty && !exists {
            actionBar.setStatus("找不到这个文件：\(name)")
        } else if isDir.boolValue {
            actionBar.setStatus("遮罩图片需要一个文件，不能是文件夹")
        } else {
            actionBar.setStatus("「\(name)」不是图片，只接受 " + DITMaskImageExtensionText())
        }
    }

    private func setMaskFromPaths(_ paths: [String]) {
        guard let candidate = DITFirstMaskImagePath(paths) else {
            reportRejectedImage(paths)
            return
        }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir) || isDir.boolValue {
            reportRejectedImage(paths)
            return
        }
        if DITEngine.probeVideoSize(candidate) == nil {
            NSSound.beep()
            actionBar.setStatus("这张图读不出来，可能不是有效的图片，或这个编码 ffmpeg 不支持")
            return
        }

        maskPath = candidate
        applyImageDisplay()
        saveDefaults()
        refreshAll()
    }

    /// 自检用：把「拖动进入 → 落点」这两步都走一遍，并把结论打到标准输出
    func simulateMaskDrop(_ paths: [String]) -> Bool {
        let accepted = imageWell.willAcceptPaths?(paths) ?? true
        let name = paths.first.map { ($0 as NSString).lastPathComponent } ?? ""
        print("遮罩拖入: \(accepted ? "接受" : "拒绝")  \(name)")
        fflush(stdout)
        if accepted { imageWell.onPaths?(paths) }
        return accepted
    }

    @objc private func chooseMaskImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择作为遮罩的图片"
        var types: [UTType] = []
        for ext in DITMaskImageExtensions.components(separatedBy: " ") where !ext.isEmpty {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        if !types.isEmpty { panel.allowedContentTypes = types }
        if panel.runModal() == .OK, let url = panel.url {
            setMaskFromPaths([url.path])
        }
    }

    // MARK: 预览

    /// 安排一次重画。after 秒内又有人来安排就作废上一次，避免连续拖动时排队跑图。
    private func schedulePreview(after delay: TimeInterval) {
        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.renderPreview()
        }
    }

    /// 真正去合成一张静帧。用的滤镜串与成品完全一致，只是最后多缩一段、只出一帧。
    private func renderPreview() {
        previewToken += 1
        let token = previewToken

        guard let source = srcPath, !source.isEmpty else {
            previewState = "没有源文件"
            previewImage.image = nil
            return
        }
        guard let size = srcSize else {
            previewState = "读不出画面尺寸"
            previewImage.image = nil
            return
        }
        let image = currentImagePath()
        if image.isEmpty {
            previewState = "没有遮罩图片"
            previewImage.image = nil
            // 没有图片时把源画面本身抽一帧出来，至少能看清这张图里有什么
            extractPlainFrame(source: source, token: token)
            return
        }
        guard let t = previewTime(quiet: true) else {
            previewState = "时刻写法不对"
            return
        }
        guard let ffmpeg = DITEngine.resolveTool("ffmpeg") else {
            previewState = "找不到 ffmpeg"
            return
        }

        let spec = buildSpec()
        let pw = Int(max(200.0, layoutView.bounds.size.width) * 2.0)
        let graph = DITMaskFilterComplex(spec, videoW: size.w, videoH: size.h, previewWidth: pw)
        let out = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ditkit-mask-preview-\(token).png")
        let args = ["-hide_banner", "-loglevel", "error",
                    "-ss", String(format: "%.3f", max(0.0, t)),
                    "-i", source, "-i", image,
                    "-filter_complex", graph,
                    "-map", "[vout]", "-frames:v", "1", "-y", out]

        previewState = "合成中"
        runPreviewProcess(ffmpeg: ffmpeg, args: args, out: out, token: token)
    }

    /// 还没选图片时给一张源画面，比一片空白有用
    private func extractPlainFrame(source: String, token: Int) {
        guard let ffmpeg = DITEngine.resolveTool("ffmpeg"),
              let t = previewTime(quiet: true) else { return }
        let pw = Int(max(200.0, layoutView.bounds.size.width) * 2.0)
        let out = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ditkit-mask-preview-\(token).png")
        let args = ["-hide_banner", "-loglevel", "error",
                    "-ss", String(format: "%.3f", max(0.0, t)),
                    "-i", source,
                    "-frames:v", "1", "-vf", "scale=\(pw):-2", "-y", out]
        runPreviewProcess(ffmpeg: ffmpeg, args: args, out: out, token: token)
    }

    private func runPreviewProcess(ffmpeg: String, args: [String], out: String, token: Int) {
        // 合成是 IO + 解码，放到后台，避免拖住界面
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // ffmpeg 在「抽不到帧」时可能不产出文件却仍退出 0 —— 不先删掉同名旧图，
            // 下面就会把上一次的残留当成这一次的结果。
            try? FileManager.default.removeItem(atPath: out)

            let task = Process()
            task.executableURL = URL(fileURLWithPath: ffmpeg)
            task.arguments = args
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            task.standardInput = FileHandle.nullDevice
            var ok = true
            do {
                try task.run()
            } catch {
                ok = false
            }
            if ok {
                task.waitUntilExit()
                if task.terminationStatus != 0 { ok = false }
            }
            // 文件真的落地才算成功
            if ok && !FileManager.default.fileExists(atPath: out) { ok = false }

            DispatchQueue.main.async {
                guard let self else { return }
                if self.previewToken != token { return }   // 已经有更新的请求了
                self.previewImage.image = ok ? NSImage(contentsOfFile: out) : nil
                self.previewState = ok ? "ok" : "失败"
            }
        }
    }

    // MARK: 文件管理

    func addInputPaths(_ paths: [String]) {
        addPaths(paths)
    }

    func beginRun() {
        startCompose()
    }

    func beginStop() {
        stopCompose()
    }

    func statusLine() -> String {
        actionBar.statusText
    }

    /// 自检用：预览区当前状态一行
    func previewLine() -> String {
        guard let picked = jobTable.previewJob else { return "没有源文件" }
        var s = "源=\(picked.job.displayName)（\(picked.fromSelection ? "选中" : "首个")）"
        if let sz = srcSize { s += " \(sz.w)x\(sz.h)" } else { s += " 尺寸未知" }
        let image = currentImagePath()
        s += " 遮罩=\(image.isEmpty ? "无" : (image as NSString).lastPathComponent)"
        s += " 构图=\(currentFit().key)/\(currentBlend().key)/\(currentOpacity())"
        // 读 previewUsedTime 而不是再解析一次输入框：这个函数是只读的诊断出口，
        // 而 previewTime 会顺手记下实际用的时刻
        s += String(format: " 时刻=%.3f", previewUsedTime)
        s += " 合成=\(previewState)"
        return s
    }

    private func addPaths(_ paths: [String]) {
        if engine?.isRunning ?? false { NSSound.beep(); return }
        let o = buildOptions()
        let files = DITEngine.videoFilesFromPaths(paths, filter: o.extensionFilter, excludeSuffix: o.suffix)

        var existing = Set<String>()
        for j in jobTable.jobs { existing.insert(j.inputPath) }

        var added = 0
        for f in files {
            if existing.contains(f) { continue }
            let job = DITJob()
            job.inputPath = f
            job.displayName = (f as NSString).lastPathComponent
            job.displayFolder = ((f as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
            jobTable.jobs.append(job)
            added += 1
        }
        if added == 0 && files.isEmpty {
            actionBar.setStatus("没有识别到可处理的视频文件（支持 mp4 / mov / mkv / mxf …）")
        }

        jobTable.reloadAll()
        refreshSourceInfo()
        refreshAll()
    }

    private func refreshSourceInfo() {
        guard let picked = jobTable.previewJob else {
            srcPath = nil
            srcSize = nil
            previewCaption.stringValue = "还没有选择视频 —— 把视频拖到下面的列表，或点「添加文件…」"
            previewCaption.textColor = NSColor.tertiaryLabelColor
            previewImage.image = nil
            previewState = "没有源文件"
            return
        }

        let job = picked.job
        srcPath = job.inputPath
        srcSize = DITEngine.probeVideoSize(job.inputPath)
        let dur = DITEngine.probeDuration(job.inputPath)

        var s = "预览源：\(job.displayName)"
        if picked.fromSelection {
            s += "（列表里选中的那个）"
        } else if jobTable.jobs.count > 1 {
            s += "（列表第一个；选中某一行可以换）"
        }
        if let sz = srcSize { s += "　·　\(sz.w)×\(sz.h)" }
        if dur > 0 { s += "　·　时长 \(DITEngine.timeStringFromSeconds(dur))" }
        previewCaption.stringValue = s
        previewCaption.textColor = NSColor.secondaryLabelColor

        schedulePreview(after: 0)
    }

    @objc private func chooseVideos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "选择要加遮罩的视频或文件夹"
        if panel.runModal() == .OK {
            addPaths(panel.urls.map(\.path))
        }
    }

    @objc private func chooseOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "选择输出目录"
        let cur = (outField.stringValue as NSString).expandingTildeInPath
        if !cur.isEmpty && cur.hasPrefix("/") {
            panel.directoryURL = URL(fileURLWithPath: cur)
        }
        if panel.runModal() == .OK, let url = panel.url {
            outField.stringValue = url.path
            saveDefaults()
        }
    }

    private func buildOptions() -> DITOutputOptions {
        let o = DITOutputOptions()
        o.outMode = (outModeSeg.selectedSegment == 1) ? .absolute : .relativeToSource
        o.outValue = outField.stringValue
        o.maxConcurrent = concurrency
        o.conflict = [.skip, .overwrite, .rename][max(0, min(2, conflictIndex))]
        o.suffix = "_mask"
        o.extensionFilter = DITMaskInputExtensions
        return o
    }

    // MARK: 任务管理

    @objc private func clearJobs() {
        if engine?.isRunning ?? false { NSSound.beep(); return }
        jobTable.jobs.removeAll()
        jobTable.reloadAll()
        actionBar.setProgress(0)
        actionBar.setStatus("就绪")
        refreshSourceInfo()
        refreshAll()
    }

    func selectAllJobs() {
        jobTable.selectAllJobs()
    }

    func selectJob(at index: Int) {
        jobTable.selectJob(at: index)
        refreshSourceInfo()
        refreshAll()
    }

    func simulateColumnResize(_ index: Int, delta: CGFloat) {
        jobTable.simulateColumnResize(index, delta: delta)
    }

    /// 只把条目从列表里去掉，不动磁盘上的文件
    @objc func deleteSelectedJobs() {
        if engine?.isRunning ?? false { NSSound.beep(); return }
        let n = jobTable.removeSelectedJobs()
        if n == 0 { NSSound.beep(); return }
        actionBar.setStatus("已从列表移除 \(n) 个（磁盘上的文件不受影响）")
        // 取样（预览）的那个可能正好被删掉了，源信息要跟着刷新
        refreshSourceInfo()
        refreshAll()
    }

    @objc private func startCompose() {
        if engine?.isRunning ?? false { return }
        let jobs = jobTable.jobs
        if jobs.isEmpty {
            NSSound.beep()
            actionBar.setStatus("还没有拖入视频")
            return
        }
        let spec = buildSpec()

        let o = buildOptions()
        let cache = DITMaskSizeCache()
        let engine = DITEngine(jobs: jobs, output: o) { job, _ in
            // 尺寸读不出来时给一组没有输入参数：ffmpeg 会立刻报错，
            // 该文件单独判失败，不会静默产出一个空文件。正常路径下 preflight 已经拦掉了。
            guard let size = cache.size(job.inputPath) else { return [] }
            return DITMaskArguments(job, spec, videoW: size.w, videoH: size.h)
        }

        engine.preflight = {
            if spec.imagePath.isEmpty { return "还没有选择遮罩图片" }
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: spec.imagePath, isDirectory: &isDir) || isDir.boolValue {
                return "遮罩图片不存在：\((spec.imagePath as NSString).lastPathComponent)"
            }
            return cache.preflight(jobs)
        }
        engine.onJobUpdate = { [weak self] job in self?.jobUpdated(job) }
        engine.onFinished = { [weak self] in self?.allFinished() }

        if let err = engine.start() {
            let a = NSAlert()
            a.messageText = "无法开始合成"
            a.informativeText = err
            a.alertStyle = .warning
            a.runModal()
            return
        }
        self.engine = engine
        refreshAll()
    }

    @objc private func stopCompose() {
        if stopping { return }              // 重复点击幂等
        guard let engine, engine.isRunning else { return }
        stopping = true
        actionBar.setStatus("正在停止…")
        actionBar.setStopEnabled(false)     // 已经在停了，别让用户反复点
        engine.cancel()
    }

    private func jobUpdated(_ job: DITJob) {
        if job.state == .done, let out = job.outputPath, !out.isEmpty {
            lastOutputDir = (out as NSString).deletingLastPathComponent
        }
        jobTable.reloadRowOfJob(job)
        updateProgress()
    }

    private func updateProgress() {
        let jobs = jobTable.jobs
        if jobs.isEmpty {
            actionBar.setProgress(0)
            return
        }
        var sum = 0.0
        var done = 0, failed = 0, skipped = 0, cancelled = 0
        var active: DITJob?
        for j in jobs {
            sum += j.progress
            switch j.state {
            case .done:      done += 1
            case .failed:    failed += 1
            case .skipped:   skipped += 1
            case .cancelled: cancelled += 1
            case .running:   active = j
            case .pending:   break
            }
        }
        actionBar.setProgress(sum / Double(jobs.count))

        // 停止过程中只刷新进度条，别用进度行盖掉「正在停止…」
        if stopping { return }

        var s = "\(done) / \(jobs.count) 完成"
        if failed > 0 { s += "　·　\(failed) 失败" }
        if skipped > 0 { s += "　·　\(skipped) 跳过" }
        if cancelled > 0 { s += "　·　\(cancelled) 已取消" }
        if let active { s += "　·　正在处理 \(active.displayName)" }
        actionBar.setStatus(s)
    }

    private func allFinished() {
        stopping = false
        updateProgress()

        var done = 0, failed = 0, skipped = 0, cancelled = 0, pending = 0
        for j in jobTable.jobs {
            switch j.state {
            case .done:      done += 1
            case .failed:    failed += 1
            case .skipped:   skipped += 1
            case .cancelled: cancelled += 1
            case .pending:   pending += 1   // 正常路径下应为 0；非 0 说明收尾漏了任务
            case .running:   pending += 1
            }
        }

        // 被停止过就换成「已停止」的说法，别把取消掉的任务伪装成成功/跳过
        let stopped = (cancelled + pending) > 0
        var s = "\(stopped ? "已停止" : "全部结束")：成功 \(done)"
        if failed > 0 { s += "　失败 \(failed)" }
        if skipped > 0 { s += "　跳过 \(skipped)" }
        if cancelled > 0 { s += "　已取消 \(cancelled)" }
        if pending > 0 { s += "　未处理 \(pending)" }
        if failed > 0 { s += "（鼠标悬停失败行可看原因）" }
        actionBar.setStatus(s)

        engine = nil
        refreshAll()
    }

    private func refreshAll() {
        let running = engine?.isRunning ?? false
        actionBar.setRunning(running, canStart: !jobTable.jobs.isEmpty)
        actionBar.setStopEnabled(running && !stopping)
        jobTable.dropEnabled = !running
        addFilesBtn.isEnabled = !running
        removeSelBtn.isEnabled = !running && jobTable.hasSelection
        outField.isEnabled = !running
        outModeSeg.isEnabled = !running
        outChooseBtn.isEnabled = !running && (outModeSeg.selectedSegment == 1)
        fitSeg.isEnabled = !running
        blendSeg.isEnabled = !running
        opacitySlider.isEnabled = !running
        qualitySlider.isEnabled = !running
        previewTimeField.isEnabled = !running
        imageWell.enabled = !running
        applyFitDisplay()
        filesCount.stringValue = jobTable.jobs.isEmpty ? "" : "已选 \(jobTable.jobs.count) 个"
    }

    private func revealOutput() {
        var dir = lastOutputDir ?? ""
        if dir.isEmpty && outModeSeg.selectedSegment == 1 {
            dir = (outField.stringValue as NSString).expandingTildeInPath
        }
        if dir.isEmpty { NSSound.beep(); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    // MARK: - CLI

    /// --cli 的用法说明
    static var cliUsage: String {
        """
        用法: DITKit --cli --mask --image <图片> [选项] -- <视频文件...>
        选项:
          --image <文件>          作为遮罩的图片（必填）
          --fit <stretch|cover|contain|original>  适配方式，默认 stretch（拉伸铺满）
          --pos <tl|center|br>    original 适配下图片的位置，默认 center
          --blend <normal|multiply|screen>        混合方式，默认 normal
          --opacity <0-100>       不透明度，默认 100（0 表示画面不受影响）
          --quality <10-90>       编码质量，默认 55
          --out <绝对目录>        输出到指定目录
          --relative <子目录>     输出到每个源文件所在目录的子目录（默认 masked）
          --jobs <N>              最大并发，默认 4
          --conflict <skip|overwrite|rename>  命名冲突策略，默认 skip
          --suffix <后缀>         输出文件名后缀，默认 _mask

        """
    }

    /// --cli 模式入口，返回进程退出码
    static func runCLI(_ argv: [String]) -> Int32 {
        let o = DITOutputOptions()
        o.suffix = "_mask"
        o.outValue = "masked"
        o.extensionFilter = DITMaskInputExtensions
        let spec = DITMaskSpec()
        spec.imagePath = ""

        var inputs: [String] = []
        var sawDashDash = false

        var i = 0
        while i < argv.count {
            let a = argv[i]
            i += 1                        // 先吃掉选项本身，下面按需再吃掉它的值
            if sawDashDash {
                inputs.append(a)
                continue
            }
            if a == "--" {
                sawDashDash = true
                continue
            }
            // --mask 是入口用来分发到本页的标记，这里必须显式跳过，
            // 否则会掉进下面的「未知选项」分支直接打印用法
            if a == "--mask" { continue }
            /// 取下一个位置的值（已经到末尾就返回 nil）
            func nextValue() -> String? { i < argv.count ? argv[i] : nil }

            switch a {
            case "--image":
                if let v = nextValue() { spec.imagePath = v }
                i += 1
            case "--fit":
                if let v = nextValue() {
                    guard let f = DITMaskFit(key: v) else {
                        FileHandle.standardError.write(Data("不认识的适配方式：\(v)（可用 stretch / cover / contain / original）\n".utf8))
                        return 2
                    }
                    spec.fit = f
                }
                i += 1
            case "--pos":
                if let v = nextValue() {
                    guard let p = DITMaskPosition(key: v) else {
                        FileHandle.standardError.write(Data("不认识的摆放位置：\(v)（可用 tl / center / br）\n".utf8))
                        return 2
                    }
                    spec.position = p
                }
                i += 1
            case "--blend":
                if let v = nextValue() {
                    guard let b = DITMaskBlend(key: v) else {
                        FileHandle.standardError.write(Data("不认识的混合方式：\(v)（可用 normal / multiply / screen）\n".utf8))
                        return 2
                    }
                    spec.blend = b
                }
                i += 1
            case "--opacity":
                if let v = nextValue() {
                    spec.opacity = max(0, min(100, (v as NSString).integerValue))
                }
                i += 1
            case "--quality":
                if let v = nextValue() { spec.quality = (v as NSString).integerValue }
                i += 1
            case "--out":
                if let v = nextValue() {
                    o.outValue = v
                    o.outMode = .absolute
                }
                i += 1
            case "--relative":
                if let v = nextValue() {
                    o.outValue = v
                    o.outMode = .relativeToSource
                }
                i += 1
            case "--jobs":
                if let v = nextValue() { o.maxConcurrent = (v as NSString).integerValue }
                i += 1
            case "--suffix":
                if let v = nextValue() { o.suffix = v }
                i += 1
            case "--conflict":
                if let v = nextValue() {
                    if v == "overwrite" { o.conflict = .overwrite }
                    else if v == "rename" { o.conflict = .rename }
                    else { o.conflict = .skip }
                }
                i += 1
            default:
                if a.hasPrefix("-") {
                    FileHandle.standardError.write(Data(cliUsage.utf8))
                    return 2
                }
                inputs.append(a)
            }
        }

        let image = (spec.imagePath as NSString).expandingTildeInPath
        if image.isEmpty {
            FileHandle.standardError.write(Data("还没有指定遮罩图片（--image）\n".utf8))
            return 2
        }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: image, isDirectory: &isDir) || isDir.boolValue {
            FileHandle.standardError.write(Data("遮罩图片不存在：\(image)\n".utf8))
            return 2
        }
        // 后缀不对的文件宁可当场拒掉：真拖到 ffmpeg 那一步，报出来的是
        // 「找不到解码器」之类跟后缀无关的话，反而难看懂
        if !DITIsMaskImagePath(image) {
            FileHandle.standardError.write(Data("「\((image as NSString).lastPathComponent)」不是图片，只接受 \(DITMaskImageExtensionText())\n".utf8))
            return 2
        }

        if inputs.isEmpty {
            FileHandle.standardError.write(Data(cliUsage.utf8))
            return 2
        }

        let files = DITEngine.videoFilesFromPaths(inputs, filter: o.extensionFilter, excludeSuffix: o.suffix)
        if files.isEmpty {
            FileHandle.standardError.write(Data("没有找到可处理的视频文件\n".utf8))
            return 2
        }

        var jobs: [DITJob] = []
        for f in files {
            let j = DITJob()
            j.inputPath = f
            j.displayName = (f as NSString).lastPathComponent
            jobs.append(j)
        }

        let cache = DITMaskSizeCache()
        if let bad = cache.preflight(jobs) {
            FileHandle.standardError.write(Data("\(bad)\n".utf8))
            return 2
        }

        var imageInfo = image
        if let sz = cache.size(image) { imageInfo += "（\(sz.w)×\(sz.h)）" }
        print("遮罩  : \(imageInfo)")
        print("适配  : \(spec.fit.key)\(spec.fit.usesPosition ? "　位置 \(spec.position.key)" : "")　混合 \(spec.blend.key)　不透明度 \(spec.opacity)%")
        print("质量  : \(spec.quality)")
        print("文件数: \(jobs.count)   并发: \(o.maxConcurrent)")
        print("")

        let engine = DITEngine(jobs: jobs, output: o) { job, _ in
            guard let size = cache.size(job.inputPath) else { return [] }
            return DITMaskArguments(job, spec, videoW: size.w, videoH: size.h)
        }

        var failed = 0
        var finished = 0
        engine.onJobUpdate = { job in
            if job.state == .done || job.state == .failed || job.state == .skipped {
                finished += 1
                switch job.state {
                case .failed:
                    failed += 1
                    print("[失败] \(job.displayName)")
                    print("       \(job.errorText)")
                case .skipped:
                    print("[跳过] \(job.displayName)")
                default:
                    print("[完成] \(job.displayName)  ->  \(job.outputPath ?? "")")
                }
                fflush(stdout)
            }
        }

        if let err = engine.start() {
            FileHandle.standardError.write(Data("错误: \(err)\n".utf8))
            return 1
        }

        DITRunLoopUntilEngineStops(engine)
        print("")
        print("结束：共 \(finished)，失败 \(failed)")
        return failed == 0 ? 0 : 1
    }
}

// MARK: - 图片文件名的判定

/// 按后缀名判断像不像图片（不看文件是否存在）
func DITIsMaskImagePath(_ path: String) -> Bool {
    let ext = (path as NSString).pathExtension.lowercased()
    guard !ext.isEmpty else { return false }
    return DITMaskImageExtensions.components(separatedBy: " ").contains(ext)
}

/// 从一批路径里挑出第一个像图片的（大小写不敏感）
func DITFirstMaskImagePath(_ paths: [String]) -> String? {
    for p in paths where DITIsMaskImagePath(p) { return p }
    return nil
}
