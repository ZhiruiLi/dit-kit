//
//  PageAudio.swift —— 工具页：音频提取
//
//  从视频或音频里切出指定区间的声音另存为音频文件，所有文件套用同一段区间。
//  起点和终点都可以留空：起点留空表示从头算起，终点留空表示一直提到结尾。
//

import AppKit

// MARK: - 输出格式

/// 输出格式。容器扩展名与编码器都由它决定，GUI 与 --cli 共用。
enum DITAudioFormat: Int, CaseIterable {
    case m4a = 0
    case mp3 = 1
    case wav = 2
    case flac = 3

    var ext: String {
        switch self {
        case .m4a:  return "m4a"
        case .mp3:  return "mp3"
        case .wav:  return "wav"
        case .flac: return "flac"
        }
    }

    var title: String { ext.uppercased() }

    /// 有损格式才有码率可言
    var isLossy: Bool { self == .m4a || self == .mp3 }

    var hint: String {
        switch self {
        case .m4a:  return "AAC 编码，体积小、兼容性最好"
        case .mp3:  return "最通用的格式，老设备也放得出来"
        case .wav:  return "无压缩 PCM，体积大，适合拿去再编辑"
        case .flac: return "无损压缩，体积比 WAV 小"
        }
    }

    init?(ext: String) {
        let e = ext.lowercased()
        guard let f = DITAudioFormat.allCases.first(where: { $0.ext == e }) else { return nil }
        self = f
    }
}

/// 可提取音频的输入：视频要，音频也要 —— 从一段录音里再切一段同样是「提取区间」
let DITAudioInputExtensions = "mp4 mov m4v mkv avi mxf ts webm flv wmv "
    + "m4a mp3 wav aac flac aiff aif ogg opus wma"

// MARK: - 提取参数

/// 提取参数（GUI 与 --cli 共用）
final class DITAudioSpec {
    var startSec: Double = 0
    /// nil 表示一直提取到结尾
    var endSec: Double?
    var format: DITAudioFormat = .m4a
    /// 有损格式的码率（kbps）
    var bitrate = 192

    /// 区间长度；终点为空（提到结尾）时返回 -1，因为长度取决于每个文件自己有多长
    var duration: Double {
        guard let e = endSec else { return -1 }
        return max(0.0, e - startSec)
    }
}

/// 提取的 ffmpeg 参数
func DITAudioArguments(_ job: DITJob, _ spec: DITAudioSpec) -> [String] {
    var a: [String] = []

    // -ss 放在 -i 之前：先定位再解码，长素材上快很多。
    // 这样输出时间戳从 0 起算，所以终点用「长度」(-t) 表达，而不是绝对时刻。
    a += ["-ss", DITEngine.timeStringFromSeconds(spec.startSec),
          "-i", job.inputPath]
    if let end = spec.endSec {
        a += ["-t", DITEngine.timeStringFromSeconds(max(0.0, end - spec.startSec))]
    }
    a += ["-vn"]        // 丢掉画面，只要声音

    switch spec.format {
    case .m4a:
        a += ["-c:a", "aac", "-b:a", "\(spec.bitrate)k"]
    case .mp3:
        a += ["-c:a", "libmp3lame", "-b:a", "\(spec.bitrate)k"]
    case .wav:
        a += ["-c:a", "pcm_s16le"]
    case .flac:
        a += ["-c:a", "flac"]
    }
    return a
}

/// 区间提示的常规文案。区间有问题时会被换成警告，恢复正常时要能原样换回来。
private func DITAudioRangeHint() -> String {
    "时间可以写 00:01:30.500，也可以写 90 / 1m30s；起点留空＝从头开始，终点留空＝提到结尾"
}

// MARK: - 波形视图

/// 整段素材的波形 + 选中区间的高亮。
///
/// 波形图由 ffmpeg 的 showwavespic 生成，这里只负责画和标区间 —— 自己算峰值
/// 需要先把整个音轨解成 PCM，而那是 ffmpeg 已经做得很好的事。
///
/// 波形横向拉开铺满：纵向缩放只是改变振幅的显示比例，时间轴仍然是线性的，
/// 所以区间的比例位置可以直接按宽度换算，不需要再考虑长宽比。
final class DITWaveformView: NSView {

    var waveform: NSImage? { didSet { needsDisplay = true } }
    /// 没有波形时居中显示的原因（「源里没有音频流」这类）
    var placeholder: String? { didSet { needsDisplay = true } }

    /// 选中区间占总时长的比例
    var startFraction: Double = 0 { didSet { needsDisplay = true } }
    var endFraction: Double = 1 { didSet { needsDisplay = true } }

    /// 自检/诊断用：区间高亮画在哪
    private(set) var bandRect: NSRect = .zero

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.0, dy: 1.0)
        if r.width < 4 || r.height < 4 { return }

        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()

        if let img = waveform {
            img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
        } else if let placeholder {
            DITDrawHintText(self, placeholder, nil,
                            [.font: NSFont.systemFont(ofSize: 12.0),
                             .foregroundColor: NSColor.tertiaryLabelColor],
                            [:])
        }

        // 中位基线：整段静音时波形是一条直线，有它才看得出「这里本来该有东西」
        NSColor.separatorColor.setStroke()
        let mid = NSBezierPath()
        mid.move(to: NSPoint(x: r.minX + 4, y: r.midY))
        mid.line(to: NSPoint(x: r.maxX - 4, y: r.midY))
        mid.lineWidth = 1.0
        mid.stroke()

        let f0 = CGFloat(max(0.0, min(1.0, startFraction)))
        let f1 = CGFloat(max(0.0, min(1.0, endFraction)))
        let x0 = r.minX + r.width * min(f0, f1)
        let x1 = r.minX + r.width * max(f0, f1)

        // 区间外压暗，区间内罩一层强调色 —— 一眼看出「会提出哪一段」
        NSColor.windowBackgroundColor.withAlphaComponent(0.55).setFill()
        NSRect(x: r.minX, y: r.minY, width: max(0.0, x0 - r.minX), height: r.height).fill(using: .sourceOver)
        NSRect(x: x1, y: r.minY, width: max(0.0, r.maxX - x1), height: r.height).fill(using: .sourceOver)

        bandRect = NSRect(x: x0, y: r.minY, width: max(1.0, x1 - x0), height: r.height)
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        bandRect.fill(using: .sourceOver)

        NSColor.controlAccentColor.setFill()
        NSRect(x: x0, y: r.minY, width: 1.0, height: r.height).fill(using: .sourceOver)
        NSRect(x: max(x0, x1 - 1.0), y: r.minY, width: 1.0, height: r.height).fill(using: .sourceOver)

        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        border.lineWidth = 1.0
        border.stroke()
    }
}

// MARK: - 工具页

final class PageAudio: NSObject, DITToolPage, NSTextFieldDelegate {

    // 控件全部先建好、再在 buildControls() 里接线（target/action 与 addSubview）。
    // 这样能用 let 而不是一堆隐式解包可选值，同时在 init 里也拿得到 self。
    private let layoutView = LayoutView(frame: NSRect(x: 0, y: 0, width: 740, height: 820))

    private let sec1Label = DITSectionLabel("1 · 源文件")
    private let sec2Label = DITSectionLabel("2 · 提取区间")
    private let sec3Label = DITSectionLabel("3 · 输出格式")
    private let sec4Label = DITSectionLabel("4 · 输出位置")
    private let sec5Label = DITSectionLabel("5 · 待处理文件")
    private let srcInfoLabel = DITLabel("", 11, false)

    private let startLabel = DITLabel("起点", 12, false)
    private let endLabel = DITLabel("终点", 12, false)
    private let startField = NSTextField(frame: .zero)
    private let endField = NSTextField(frame: .zero)
    private let wholeBtn = NSButton(frame: .zero)
    private let waveCaption = DITLabel("", 11, false)
    private let waveform = DITWaveformView(frame: .zero)
    private let lenLabel = DITLabel("", 11, false)
    private let rangeHint = DITLabel(DITAudioRangeHint(), 11, false)

    private let formatSeg = NSSegmentedControl(frame: .zero)
    private let bitrateSlider = NSSlider(frame: .zero)
    private let bitrateValue = DITLabel("192", 12, false)
    private let formatHint = DITLabel("", 11, false)

    private let outModeSeg = NSSegmentedControl(frame: .zero)
    private let outField = NSTextField(frame: .zero)
    private let outChooseBtn = NSButton(frame: .zero)
    private let outHintLabel = DITLabel("", 11, false)

    private let filesCount = DITLabel("", 11, false)
    private let addFilesBtn = DITButton("添加文件…", nil, nil)
    private let removeSelBtn = DITButton("删除选中", nil, nil)
    private let jobTable = DITJobTable()
    private let actionBar = DITActionBar()

    private var engine: DITEngine?
    /// 第一个源文件（音频信息取样）
    private var srcPath: String?
    private var srcDuration: Double = 0
    private var lastOutputDir: String?
    /// 已点击停止、等引擎收尾；期间不让进度行覆盖提示
    private var stopping = false
    /// 并发数（沿用偏好里的设定）
    private var concurrency = 4
    /// 命名冲突策略
    private var conflictIndex = 0
    /// 防止旧的波形结果覆盖新画面
    private var waveToken = 0
    /// 波形状态（没有源 / 没有音轨 / 生成中 / 成功 / 失败），给诊断行用
    private var waveState = "—"

    override init() {
        super.init()
        buildControls()
        loadDefaults()
        refreshSourceInfo()   // 空列表时也要把引导语摆上
        refreshAll()
    }

    // MARK: 协议

    var view: NSView { layoutView }
    var pageTitle: String { "音频提取" }
    var busy: Bool { engine?.isRunning ?? false }

    func layoutInBounds(_ bounds: NSRect) {
        doLayout()
    }

    // MARK: 构建界面

    private func buildControls() {
        layoutView.onLayout = { [weak self] in self?.doLayout() }

        // 1 · 源文件（只报当前取样的那一个；拖入统一走下面的列表）
        srcInfoLabel.lineBreakMode = .byTruncatingTail
        layoutView.addSubview(sec1Label)
        layoutView.addSubview(srcInfoLabel)

        // 2 · 提取区间
        layoutView.addSubview(sec2Label)
        layoutView.addSubview(startLabel)

        startField.placeholderString = "留空＝从头"
        startField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        startField.delegate = self
        startField.target = self
        startField.action = #selector(rangeEdited)
        layoutView.addSubview(startField)

        layoutView.addSubview(endLabel)

        endField.placeholderString = "留空＝到结尾"
        endField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        endField.delegate = self
        endField.target = self
        endField.action = #selector(rangeEdited)
        layoutView.addSubview(endField)

        wholeBtn.title = "整段（到结尾）"
        wholeBtn.bezelStyle = .rounded
        wholeBtn.target = self
        wholeBtn.action = #selector(useWholeFile)
        layoutView.addSubview(wholeBtn)

        // 整段波形 + 选中区间：这一页没有画面可看，波形就是「大致效果」
        waveCaption.lineBreakMode = .byTruncatingTail
        layoutView.addSubview(waveCaption)
        layoutView.addSubview(waveform)

        layoutView.addSubview(lenLabel)
        layoutView.addSubview(rangeHint)

        // 3 · 输出格式
        layoutView.addSubview(sec3Label)

        formatSeg.segmentCount = DITAudioFormat.allCases.count
        for f in DITAudioFormat.allCases {
            formatSeg.setLabel(f.title, forSegment: f.rawValue)
        }
        formatSeg.selectedSegment = DITAudioFormat.m4a.rawValue
        formatSeg.segmentStyle = .rounded
        formatSeg.target = self
        formatSeg.action = #selector(formatChanged)
        layoutView.addSubview(formatSeg)

        bitrateSlider.minValue = 64
        bitrateSlider.maxValue = 320
        bitrateSlider.doubleValue = 192
        bitrateSlider.isContinuous = true
        bitrateSlider.target = self
        bitrateSlider.action = #selector(bitrateChanged)
        layoutView.addSubview(bitrateSlider)

        layoutView.addSubview(bitrateValue)
        layoutView.addSubview(formatHint)

        // 4 · 输出位置
        layoutView.addSubview(sec4Label)

        outModeSeg.segmentCount = 2
        outModeSeg.setLabel("相对源文件", forSegment: 0)
        outModeSeg.setLabel("绝对路径", forSegment: 1)
        outModeSeg.selectedSegment = 0
        outModeSeg.segmentStyle = .rounded
        outModeSeg.target = self
        outModeSeg.action = #selector(outModeChanged)
        layoutView.addSubview(outModeSeg)

        outField.placeholderString = "audio"
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

        // 5 · 待处理文件（列表本身就是拖入区）
        layoutView.addSubview(sec5Label)

        filesCount.alignment = .right
        layoutView.addSubview(filesCount)

        addFilesBtn.target = self
        addFilesBtn.action = #selector(chooseFiles)
        layoutView.addSubview(addFilesBtn)

        removeSelBtn.target = self
        removeSelBtn.action = #selector(deleteSelectedJobs)
        layoutView.addSubview(removeSelBtn)

        jobTable.emptyHint = "把要提取音频的文件拖到这里"
        jobTable.emptySubHint = "视频与音频都收；支持多选、多目录与整个文件夹，所有文件套用同一段区间"
        jobTable.onDropPaths = { [weak self] paths in self?.addPaths(paths) }
        jobTable.onSelectionChanged = { [weak self] in
            // 选中项决定波形画的是哪一个，所以选中变化也要重新取样
            self?.refreshSourceInfo()
            self?.refreshAll()
        }
        jobTable.onDeleteRequested = { [weak self] in self?.deleteSelectedJobs() }

        layoutView.addSubview(jobTable.scrollView)

        // 底部
        actionBar.setStartTitle("开始提取")
        actionBar.addToView(layoutView)
        actionBar.onStart = { [weak self] in self?.startExtract() }
        actionBar.onStop = { [weak self] in self?.stopExtract() }
        actionBar.onClear = { [weak self] in self?.clearJobs() }
        actionBar.onReveal = { [weak self] in self?.revealOutput() }
    }

    // MARK: 布局

    private func doLayout() {
        if layoutView.superview == nil { return }
        let b = layoutView.bounds
        let W = b.size.width
        let H = b.size.height
        let PAD: CGFloat = 18.0
        let x = PAD
        let w = W - PAD * 2
        var y = PAD

        // 1 · 源文件（只有一行信息）
        DITPlaceSection(sec1Label, &y, x, w)
        DITFrame(srcInfoLabel, x, y, w, 14)
        y += 14 + 14

        // 2 · 提取区间（下面接整段波形，选中的那一段会被标出来）
        DITPlaceSection(sec2Label, &y, x, w)
        DITFrame(startLabel, x, y + 3, 32, 18)
        DITFrame(startField, x + 36, y, 140, 24)
        DITFrame(endLabel, x + 190, y + 3, 32, 18)
        DITFrame(endField, x + 226, y, 140, 24)
        let wholeW: CGFloat = 130.0
        DITFrame(wholeBtn, x + w - wholeW, y, wholeW, 24)
        y += 24 + 8

        // 波形要够高才看得出区间落在哪，但也不能把列表挤没了：按窗口高度分给它
        DITFrame(waveCaption, x, y, w, 14)
        y += 14 + 4

        let wv = min(170.0, max(100.0, H - 620.0))
        DITFrame(waveform, x, y, w, wv)
        y += wv + 6

        // 长度与估算独占一行，不和按钮抢宽度
        DITFrame(lenLabel, x, y, w, 16)
        y += 16 + 4
        DITFrame(rangeHint, x, y, w, 14)
        y += 14 + 14

        // 3 · 输出格式
        DITPlaceSection(sec3Label, &y, x, w)
        DITFrame(formatSeg, x, y, 300, 24)
        DITFrame(bitrateSlider, x + 320, y + 1, 150, 22)
        DITFrame(bitrateValue, x + 476, y + 2, 44, 18)
        y += 24 + 6
        DITFrame(formatHint, x, y, w, 14)
        y += 14 + 14

        // 4 · 输出位置
        DITPlaceSection(sec4Label, &y, x, w)
        DITFrame(outModeSeg, x, y, 280, 24)
        y += 24 + 8
        let btnW: CGFloat = 88
        DITFrame(outField, x, y, w - btnW - 8, 24)
        DITFrame(outChooseBtn, x + w - btnW, y, btnW, 24)
        y += 24 + 4
        DITFrame(outHintLabel, x, y, w, 14)
        y += 14 + 14

        // 5 · 文件清单（标题行右边放「添加文件…／删除选中」，计数贴左）
        let rh: CGFloat = 24.0
        DITFrame(sec5Label, x, y + 4, w * 0.5, 16)
        let bw2: CGFloat = 92.0, bgap: CGFloat = 8.0
        DITFrame(removeSelBtn, x + w - bw2, y, bw2, rh)
        DITFrame(addFilesBtn, x + w - bw2 * 2 - bgap, y, bw2, rh)
        DITFrame(filesCount, x + w * 0.5, y + 6, w * 0.5 - bw2 * 2 - bgap - 8, 14)
        y += rh + 8

        // 底部操作栏
        let tableBottom = actionBar.layoutFromBottom(H - PAD, x: x, width: w)

        jobTable.layoutColumnsForWidth(w)
        DITFrame(jobTable.scrollView, x, y, w, max(60, tableBottom - y))
    }

    // MARK: 偏好

    private func loadDefaults() {
        let d = UserDefaults.standard

        let mode = d.integer(forKey: "audio.outMode")
        outModeSeg.selectedSegment = (mode == 1) ? 1 : 0
        let outVal = d.string(forKey: "audio.outValue") ?? ""
        outField.stringValue = outVal.isEmpty ? "audio" : outVal

        var conf = d.integer(forKey: "audio.conflict")
        if conf < 0 || conf > 2 { conf = 0 }
        conflictIndex = conf

        var conc = d.integer(forKey: "audio.concurrency")
        if conc <= 0 { conc = 4 }
        concurrency = conc

        var q = d.integer(forKey: "audio.bitrate")
        if q < 64 || q > 320 { q = 192 }
        bitrateSlider.doubleValue = Double(q)

        let f = d.integer(forKey: "audio.format")
        formatSeg.selectedSegment = DITAudioFormat(rawValue: f)?.rawValue ?? DITAudioFormat.m4a.rawValue

        var s = d.string(forKey: "audio.start") ?? ""
        var e = d.string(forKey: "audio.end") ?? ""
        // 自检 / 截图预览时可用环境变量注入区间与格式，避免污染用户偏好
        let env = ProcessInfo.processInfo.environment
        if let sEnv = env["DITKIT_AUDIO_START"] { s = sEnv }
        if let eEnv = env["DITKIT_AUDIO_END"] { e = eEnv }
        if let fEnv = env["DITKIT_AUDIO_FORMAT"], let af = DITAudioFormat(ext: fEnv) {
            formatSeg.selectedSegment = af.rawValue
        }
        startField.stringValue = s
        endField.stringValue = e

        outModeChanged()
        formatChanged()
        updateRangeInfo()
    }

    @objc private func saveDefaults() {
        let d = UserDefaults.standard
        d.set(outModeSeg.selectedSegment, forKey: "audio.outMode")
        d.set(outField.stringValue, forKey: "audio.outValue")
        d.set(conflictIndex, forKey: "audio.conflict")
        d.set(concurrency, forKey: "audio.concurrency")
        d.set(Int(bitrateSlider.doubleValue), forKey: "audio.bitrate")
        d.set(formatSeg.selectedSegment, forKey: "audio.format")
        d.set(startField.stringValue, forKey: "audio.start")
        d.set(endField.stringValue, forKey: "audio.end")
    }

    // MARK: 交互

    private func currentFormat() -> DITAudioFormat {
        DITAudioFormat(rawValue: formatSeg.selectedSegment) ?? .m4a
    }

    private func currentBitrate() -> Int { Int(bitrateSlider.doubleValue) }

    /// 码率只对有损格式有意义：无损时把数值换成破折号并压暗成不可编辑的样子，
    /// 免得那个数字看起来像是生效的。
    private func updateBitrateUI() {
        let lossy = currentFormat().isLossy
        bitrateValue.stringValue = lossy ? "\(currentBitrate())k" : "—"
        bitrateValue.textColor = lossy ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
        bitrateSlider.isEnabled = lossy && !(engine?.isRunning ?? false)
    }

    @objc private func outModeChanged() {
        let absolute = (outModeSeg.selectedSegment == 1)
        outChooseBtn.isEnabled = absolute
        if absolute {
            outField.placeholderString = "/Users/you/Movies/audio"
            outHintLabel.stringValue = "带 ~ 会自动展开；目录不存在会自动创建"
        } else {
            outField.placeholderString = "audio"
            outHintLabel.stringValue = "相对每个源文件所在目录；填 . 表示输出到源文件同目录"
        }
        saveDefaults()
    }

    @objc private func formatChanged() {
        formatHint.stringValue = currentFormat().hint
        updateBitrateUI()
        saveDefaults()
        updateRangeInfo()      // 体积估算只对有损格式有意义
    }

    @objc private func bitrateChanged() {
        updateBitrateUI()
        saveDefaults()
        updateRangeInfo()
    }

    /// 输入框失焦或回车后，重新校验区间
    @objc func controlTextDidEndEditing(_ note: Notification) {
        rangeEdited()
    }

    @objc private func rangeEdited() {
        updateRangeInfo()
        updateWaveformRange()
        saveDefaults()
    }

    /// 两个框都清空 —— 起点留空＝从头，终点留空＝到结尾，合起来就是整段
    @objc private func useWholeFile() {
        startField.stringValue = ""
        endField.stringValue = ""
        rangeEdited()
    }

    /// 解析区间。起点留空当 0，终点留空当「提到结尾」（end 为 nil）。
    /// 返回 nil 表示写法不合法；quiet = false 时会把原因写进状态栏。
    private func currentRange(quiet: Bool) -> (start: Double, end: Double?)? {
        let sText = startField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let eText = endField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        var start = 0.0
        if !sText.isEmpty {
            start = DITEngine.secondsFromTimeString(sText)
            if start < 0 {
                if !quiet { actionBar.setStatus("起点时间格式看不懂：请用 00:01:30.500 或 90 / 1m30s") }
                return nil
            }
        }

        var end: Double?
        if !eText.isEmpty {
            let v = DITEngine.secondsFromTimeString(eText)
            if v < 0 {
                if !quiet { actionBar.setStatus("终点时间格式看不懂：请用 00:01:30.500 或 90 / 1m30s") }
                return nil
            }
            end = v
        }

        if let e = end, e <= start {
            if !quiet { actionBar.setStatus("终点必须大于起点") }
            return nil
        }
        return (start, end)
    }

    private func updateRangeInfo() {
        let normal = DITAudioRangeHint()

        guard let range = currentRange(quiet: true) else {
            lenLabel.stringValue = "区间无效"
            lenLabel.textColor = NSColor.systemRed
            rangeHint.stringValue = normal
            rangeHint.textColor = NSColor.secondaryLabelColor
            return
        }

        let s = range.start
        let f = currentFormat()

        // 长度：终点给了就直接算，没给就按第一个文件的时长估算（各文件长度不同，只能估）
        var length: Double = -1
        var text: String
        if let e = range.end {
            length = e - s
            text = "区间长度 \(DITEngine.timeStringFromSeconds(length))"
        } else if srcDuration > 0 {
            length = max(0.0, srcDuration - s)
            text = "到结尾，按第一个文件约 \(DITEngine.timeStringFromSeconds(length))"
        } else {
            text = "到结尾"
        }
        if f.isLossy && length > 0 {
            let mb = Double(currentBitrate()) * 1000.0 / 8.0 * length / 1048576.0
            text += String(format: "　·　约 %.1f MB", mb)
        }
        lenLabel.stringValue = text
        lenLabel.textColor = NSColor.secondaryLabelColor

        // 警告独占下面整行；两个越界情形都只说一句，不叠加
        func warn(_ msg: String) {
            rangeHint.stringValue = msg
            rangeHint.textColor = NSColor.systemOrange
        }
        if srcDuration > 0 && s >= srcDuration {
            warn("起点已经在第一个文件的时长（\(DITEngine.timeStringFromSeconds(srcDuration))）之外，提取不到声音")
        } else if let e = range.end, srcDuration > 0, e > srcDuration + 0.05 {
            warn("终点超出第一个文件的时长 \(DITEngine.timeStringFromSeconds(srcDuration))，成品会截断到结尾")
        } else {
            rangeHint.stringValue = normal
            rangeHint.textColor = NSColor.secondaryLabelColor
        }
    }

    // MARK: 文件管理

    func addInputPaths(_ paths: [String]) {
        addPaths(paths)
    }

    func beginRun() {
        startExtract()
    }

    func beginStop() {
        stopExtract()
    }

    func statusLine() -> String {
        actionBar.statusText
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
            actionBar.setStatus("没有识别到可提取的文件（支持视频与常见音频格式）")
        }

        // 第一个文件用来取音频信息
        refreshSourceInfo()
        jobTable.reloadAll()
        refreshAll()
    }

    private func refreshSourceInfo() {
        guard let picked = jobTable.previewJob else {
            srcPath = nil
            srcDuration = 0
            srcInfoLabel.stringValue = "还没有选择文件 —— 把视频或音频拖到下面的列表，或点「添加文件…」"
            srcInfoLabel.textColor = NSColor.tertiaryLabelColor
            waveCaption.stringValue = "整段波形会画在这里"
            waveCaption.textColor = NSColor.tertiaryLabelColor
            waveform.waveform = nil
            waveform.placeholder = nil
            waveState = "没有源文件"
            updateWaveformRange()
            updateRangeInfo()
            return
        }
        let first = picked.job
        srcPath = first.inputPath
        srcDuration = DITEngine.probeDuration(first.inputPath)

        // 音频概况排在时长前面：自检诊断会把标签截到 26 个字符，
        // 而这个页面最要紧的信息就是「源里有没有声音、是什么规格」
        var s = first.displayName
        if let audio = DITEngine.probeAudioSummary(first.inputPath) {
            s += "　·　\(audio)"
        } else {
            // 不拦着开始：批量里只有部分文件没声音时，挡下整批反而更糟
            s += "　·　没有音频流，提取会失败"
        }
        if srcDuration > 0 { s += "　·　时长 \(DITEngine.timeStringFromSeconds(srcDuration))" }
        if jobTable.jobs.count > 1 { s += "　·　共 \(jobTable.jobs.count) 个文件" }
        srcInfoLabel.stringValue = s
        srcInfoLabel.textColor = NSColor.secondaryLabelColor

        // 波形画的是哪一条要说清楚：列表里选中一个就画它，否则画第一个
        var c = "波形：\(first.displayName)"
        if picked.fromSelection {
            c += "（列表里选中的那个）"
        } else if jobTable.jobs.count > 1 {
            c += "（列表第一个；选中某一行可以换）"
        }
        waveCaption.stringValue = c
        waveCaption.textColor = NSColor.secondaryLabelColor

        updateWaveformRange()
        scheduleWaveform()
        updateRangeInfo()
    }

    // MARK: 波形预览

    /// 把选中区间换算成 0..1 的比例交给波形视图。时间超界时夹到两端。
    private func updateWaveformRange() {
        guard srcDuration > 0, let range = currentRange(quiet: true) else {
            waveform.startFraction = 0
            waveform.endFraction = 1
            return
        }
        waveform.startFraction = max(0.0, min(1.0, range.start / srcDuration))
        let end = range.end ?? srcDuration
        waveform.endFraction = max(0.0, min(1.0, end / srcDuration))
    }

    /// 生成整段波形图（ffmpeg 的 showwavespic）。
    private func scheduleWaveform() {
        waveToken += 1
        let token = waveToken

        guard let src = srcPath, !src.isEmpty else {
            waveform.waveform = nil
            waveform.placeholder = nil
            waveState = "没有源文件"
            return
        }
        guard DITEngine.probeAudioStream(src) != nil else {
            waveform.waveform = nil
            waveform.placeholder = "这个文件里没有音频流，画不出波形"
            waveState = "没有音频流"
            return
        }
        guard let ffmpeg = DITEngine.resolveTool("ffmpeg") else {
            waveform.waveform = nil
            waveform.placeholder = "找不到 ffmpeg，画不出波形"
            waveState = "找不到 ffmpeg"
            return
        }

        // 长素材只画前一段：画整段要把整个音轨解码一遍，为了一张缩略图不值得
        let cap: Double = 20 * 60
        let capped = srcDuration > cap

        let out = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ditkit-waveform-\(token).png")
        var args = ["-hide_banner", "-loglevel", "error"]
        if capped { args += ["-t", String(cap)] }
        args += ["-i", src,
                 "-filter_complex", "showwavespic=s=1200x220:colors=0x4d8df0",
                 "-frames:v", "1", "-y", out]

        waveState = "生成中"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 不先删掉同名旧图的话，ffmpeg 没产出时会把残留当成这次的结果
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
            if ok && !FileManager.default.fileExists(atPath: out) { ok = false }

            DispatchQueue.main.async {
                guard let self else { return }
                if self.waveToken != token { return }   // 已经有更新的请求了
                self.waveform.waveform = ok ? NSImage(contentsOfFile: out) : nil
                self.waveform.placeholder = ok ? nil : "画不出波形"
                self.waveState = ok ? "ok" : "失败"
                self.waveCaption.stringValue = capped
                    ? "波形：\(self.srcPath.map { ($0 as NSString).lastPathComponent } ?? "")（只画了前 20 分钟）"
                    : self.waveCaption.stringValue
            }
        }
    }

    /// 自检用：波形区当前状态一行
    func previewLine() -> String {
        guard let picked = jobTable.previewJob else { return "没有源文件" }
        var s = "源=\(picked.job.displayName)（\(picked.fromSelection ? "选中" : "首个")）"
        s += " 波形=\(waveState)"
        if let range = currentRange(quiet: true) {
            let end = range.end.map { DITEngine.timeStringFromSeconds($0) } ?? "结尾"
            s += " 区间=\(DITEngine.timeStringFromSeconds(range.start))→\(end)"
        } else {
            s += " 区间=无效"
        }
        // 高亮带的实际绘制位置：区间比例算得对不对，从这几个数上一眼能看出来
        s += String(format: " 带=%.1f+%.1f/%.1f",
                    waveform.bandRect.minX, waveform.bandRect.width, waveform.bounds.width)
        return s
    }

    @objc private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "选择要提取音频的视频、音频或文件夹"
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
        o.suffix = "_audio"
        // 输出容器由格式决定，不能沿用源文件的扩展名（视频进来、音频出去）
        o.outputExtension = currentFormat().ext
        o.extensionFilter = DITAudioInputExtensions
        return o
    }

    private func buildSpec() -> DITAudioSpec? {
        guard let range = currentRange(quiet: true) else { return nil }
        let spec = DITAudioSpec()
        spec.startSec = range.start
        spec.endSec = range.end
        spec.format = currentFormat()
        spec.bitrate = currentBitrate()
        return spec
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
        // 取样的第一个文件可能正好被删掉了，源信息要跟着刷新
        refreshSourceInfo()
        refreshAll()
    }

    @objc private func startExtract() {
        if engine?.isRunning ?? false { return }
        if jobTable.jobs.isEmpty {
            NSSound.beep()
            actionBar.setStatus("还没有拖入文件")
            return
        }
        guard let spec = buildSpec() else { return }
        if let e = spec.endSec, e - spec.startSec < 0.04 {
            actionBar.setStatus("区间太短了（至少约 1 帧）")
            return
        }

        let o = buildOptions()
        let engine = DITEngine(jobs: jobTable.jobs, output: o) { job, _ in
            DITAudioArguments(job, spec)
        }

        // 进度分母：给了终点就是区间长度；留空则各文件长度不同，只能现探一次源时长。
        // 这一次 ffprobe 每个文件只跑一遍，代价远小于把进度算错。
        engine.expectedDuration = { job in
            if let e = spec.endSec { return e - spec.startSec }
            let d = DITEngine.probeDuration(job.inputPath)
            return d > 0 ? max(0.0, d - spec.startSec) : 0
        }

        engine.onJobUpdate = { [weak self] job in self?.jobUpdated(job) }
        engine.onFinished = { [weak self] in self?.allFinished() }

        if let err = engine.start() {
            let a = NSAlert()
            a.messageText = "无法开始提取"
            a.informativeText = err
            a.alertStyle = .warning
            a.runModal()
            return
        }
        self.engine = engine
        refreshAll()
    }

    @objc private func stopExtract() {
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
        startField.isEnabled = !running
        endField.isEnabled = !running
        wholeBtn.isEnabled = !running
        formatSeg.isEnabled = !running
        updateBitrateUI()
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
        用法: DITKit --cli --audio [--start <起点>] [--end <终点>] [选项] -- <文件...>
        选项:
          --start <时间>          区间起点，默认从头开始
          --end <时间>            区间终点，默认一直提到结尾
          --format <m4a|mp3|wav|flac>  输出格式，默认 m4a
          --bitrate <64-320>      有损格式的码率 kbps，默认 192
          --out <绝对目录>        输出到指定目录
          --relative <子目录>     输出到每个源文件所在目录的子目录（默认 audio）
          --jobs <N>              最大并发，默认 4
          --conflict <skip|overwrite|rename>  命名冲突策略，默认 skip
          --suffix <后缀>         输出文件名后缀，默认 _audio
        时间可以写 00:01:30.500，也可以写 90 / 1m30s

        """
    }

    /// --cli 模式入口，返回进程退出码
    static func runCLI(_ argv: [String]) -> Int32 {
        let o = DITOutputOptions()
        o.suffix = "_audio"
        o.outValue = "audio"
        o.extensionFilter = DITAudioInputExtensions
        let spec = DITAudioSpec()
        var sawEnd = false

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
            // --audio 是入口用来分发到本页的标记，这里必须显式跳过，
            // 否则会掉进下面的「未知选项」分支直接打印用法
            if a == "--audio" { continue }
            /// 取下一个位置的值（已经到末尾就返回 nil）
            func nextValue() -> String? { i < argv.count ? argv[i] : nil }

            switch a {
            case "--start":
                if let v = nextValue() {
                    let sec = DITEngine.secondsFromTimeString(v)
                    if sec < 0 {
                        FileHandle.standardError.write(Data("起点时间格式看不懂\n".utf8))
                        return 2
                    }
                    spec.startSec = sec
                }
                i += 1
            case "--end":
                if let v = nextValue() {
                    let sec = DITEngine.secondsFromTimeString(v)
                    if sec < 0 {
                        FileHandle.standardError.write(Data("终点时间格式看不懂\n".utf8))
                        return 2
                    }
                    spec.endSec = sec
                    sawEnd = true
                }
                i += 1
            case "--format":
                if let v = nextValue() {
                    guard let f = DITAudioFormat(ext: v) else {
                        FileHandle.standardError.write(Data("不认识的输出格式：\(v)（可用 m4a / mp3 / wav / flac）\n".utf8))
                        return 2
                    }
                    spec.format = f
                }
                i += 1
            case "--bitrate":
                if let v = nextValue() {
                    let k = (v as NSString).integerValue
                    spec.bitrate = max(64, min(320, k))
                }
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

        if inputs.isEmpty {
            FileHandle.standardError.write(Data(cliUsage.utf8))
            return 2
        }
        if let e = spec.endSec, e <= spec.startSec {
            FileHandle.standardError.write(Data("终点必须大于起点\n".utf8))
            return 2
        }
        o.outputExtension = spec.format.ext

        let files = DITEngine.videoFilesFromPaths(inputs, filter: o.extensionFilter, excludeSuffix: o.suffix)
        if files.isEmpty {
            FileHandle.standardError.write(Data("没有找到可提取音频的文件\n".utf8))
            return 2
        }

        var jobs: [DITJob] = []
        for f in files {
            let j = DITJob()
            j.inputPath = f
            j.displayName = (f as NSString).lastPathComponent
            jobs.append(j)
        }

        let rangeText = sawEnd
            ? "\(DITEngine.timeStringFromSeconds(spec.startSec)) → \(DITEngine.timeStringFromSeconds(spec.endSec ?? 0))（\(DITEngine.timeStringFromSeconds(spec.duration))）"
            : "\(DITEngine.timeStringFromSeconds(spec.startSec)) → 结尾"
        print("区间  : \(rangeText)")
        print("格式  : \(spec.format.ext)\(spec.format.isLossy ? "　码率 \(spec.bitrate)k" : "")")
        print("文件数: \(jobs.count)   并发: \(o.maxConcurrent)")
        print("")

        let engine = DITEngine(jobs: jobs, output: o) { job, _ in
            DITAudioArguments(job, spec)
        }
        engine.expectedDuration = { job in
            if let e = spec.endSec { return e - spec.startSec }
            let d = DITEngine.probeDuration(job.inputPath)
            return d > 0 ? max(0.0, d - spec.startSec) : 0
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
