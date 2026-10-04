//
//  PageTrim.swift —— 工具页：视频裁剪
//
//  切出指定范围内的一段视频并另存。支持两种切法：
//    · 快速：`-c copy` 流复制，秒级完成，但起点会吸附到最近的关键帧
//    · 精确：重编码，帧级精确，耗时与片段长度成正比
//

import AppKit

// MARK: - 裁剪参数

/// 裁剪参数（GUI 与 --cli 共用）
final class DITTrimSpec {
    var startSec: Double = 0
    var endSec: Double = 10
    /// true = 流复制，false = 重编码
    var fastCopy = true
    var quality = 55

    var duration: Double { max(0.0, endSec - startSec) }
}

/// 裁剪的 ffmpeg 参数
func DITTrimArguments(_ job: DITJob, _ spec: DITTrimSpec) -> [String] {
    var a: [String] = []

    // -ss 放在 -i 之前：先定位再解码，长素材上快很多
    a += ["-ss", DITEngine.timeStringFromSeconds(spec.startSec),
          "-i", job.inputPath,
          "-t", DITEngine.timeStringFromSeconds(spec.duration)]

    if spec.fastCopy {
        // 流复制：不重编码，速度快到几乎瞬时；起点只能落在关键帧上
        a += ["-c", "copy"]
    } else {
        a += ["-c:v", "hevc_videotoolbox",
              "-q:v", String(spec.quality),
              "-pix_fmt", "p010le"]
        let lowExt = (job.inputPath as NSString).pathExtension.lowercased()
        if lowExt == "mp4" || lowExt == "mov" || lowExt == "m4v" {
            a += ["-tag:v", "hvc1"]
        }
        // 切点不落在音频帧边界上，音频必须重编码才能对齐
        a += ["-c:a", "aac", "-b:a", "192k"]
    }
    return a
}

/// 裁剪范围下方那行提示的常规文案。
/// 抽出来是因为 updateLengthLabel 在范围超出源时长时会把它换成警告，
/// 恢复正常时得能原样换回来。
private func DITRangeHintText() -> String {
    "时间可以写 00:01:30.500，也可以写 90 / 1m30s；改完按回车刷新画面"
}

// MARK: - 工具页

final class PageTrim: NSObject, DITToolPage, NSTextFieldDelegate {

    // 控件全部先建好、再在 buildControls() 里接线（target/action 与 addSubview）。
    // 这样能用 let 而不是一堆隐式解包可选值，同时在 init 里也拿得到 self。
    private let layoutView = LayoutView(frame: NSRect(x: 0, y: 0, width: 740, height: 820))

    private let sec1Label = DITSectionLabel("1 · 源视频")
    private let sec2Label = DITSectionLabel("2 · 裁剪范围")
    private let sec3Label = DITSectionLabel("3 · 输出")
    private let sec4Label = DITSectionLabel("4 · 裁剪方式")
    private let sec5Label = DITSectionLabel("5 · 待裁剪文件")
    private let srcInfoLabel = DITLabel("", 11, false)

    private let startLabel = DITLabel("起点", 12, false)
    private let endLabel = DITLabel("终点", 12, false)
    private let lenLabel = DITLabel("", 11, false)
    private let startField = NSTextField(frame: .zero)
    private let endField = NSTextField(frame: .zero)
    private let fullRangeBtn = NSButton(frame: .zero)
    private let rangeHint = DITLabel(DITRangeHintText(), 11, false)

    private let startThumb = NSImageView(frame: .zero)
    private let endThumb = NSImageView(frame: .zero)
    private let startThumbLabel = DITLabel("起点画面", 11, false)
    private let endThumbLabel = DITLabel("终点画面", 11, false)

    private let outModeSeg = NSSegmentedControl(frame: .zero)
    private let outField = NSTextField(frame: .zero)
    private let outChooseBtn = NSButton(frame: .zero)
    private let outHintLabel = DITLabel("", 11, false)

    private let fastRadio = NSButton(frame: .zero)
    private let exactRadio = NSButton(frame: .zero)
    private let qualitySlider = NSSlider(frame: .zero)
    private let qualityValue = DITLabel("55", 12, false)
    private let modeHint = DITLabel("", 11, false)

    private let filesCount = DITLabel("", 11, false)
    private let addFilesBtn = DITButton("添加文件…", nil, nil)
    private let removeSelBtn = DITButton("删除选中", nil, nil)
    private let jobTable = DITJobTable()
    private let actionBar = DITActionBar()

    private var engine: DITEngine?
    /// 第一个源文件（媒体信息与缩略图取样）
    private var srcPath: String?
    private var srcDuration: Double = 0
    private var lastOutputDir: String?
    /// 已点击停止、等引擎收尾；期间不让进度行覆盖提示
    private var stopping = false
    /// 防止旧抽帧结果覆盖新画面
    private var thumbToken = 0
    /// 并发数（沿用偏好里的设定）
    private var concurrency = 4
    /// 命名冲突策略
    private var conflictIndex = 0

    override init() {
        super.init()
        buildControls()
        loadDefaults()
        refreshSourceInfo()    // 空列表时也要把引导语摆上
        refreshAll()
    }

    // MARK: 协议

    var view: NSView { layoutView }
    var pageTitle: String { "视频裁剪" }
    var busy: Bool { engine?.isRunning ?? false }

    func layoutInBounds(_ bounds: NSRect) {
        doLayout()
    }

    // MARK: 构建界面

    private func buildControls() {
        layoutView.onLayout = { [weak self] in self?.doLayout() }

        // 1 · 源视频（拖入统一走下面的列表，这里只报当前取样的那一个）
        layoutView.addSubview(sec1Label)
        layoutView.addSubview(srcInfoLabel)

        // 2 · 裁剪范围
        layoutView.addSubview(sec2Label)
        layoutView.addSubview(startLabel)

        startField.placeholderString = "00:00:00.000"
        startField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        startField.delegate = self
        startField.target = self
        startField.action = #selector(rangeEdited)
        layoutView.addSubview(startField)

        layoutView.addSubview(endLabel)

        endField.placeholderString = "00:00:10.000"
        endField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        endField.delegate = self
        endField.target = self
        endField.action = #selector(rangeEdited)
        layoutView.addSubview(endField)

        // 这行字要和右边的按钮挤在一排，放不下时给省略号，别硬顶过去
        lenLabel.lineBreakMode = .byTruncatingTail
        layoutView.addSubview(lenLabel)

        fullRangeBtn.title = "用完整时长"
        fullRangeBtn.bezelStyle = .rounded
        fullRangeBtn.target = self
        fullRangeBtn.action = #selector(useFullRange)
        layoutView.addSubview(fullRangeBtn)

        for (iv, label) in [(startThumb, startThumbLabel), (endThumb, endThumbLabel)] {
            iv.imageFrameStyle = .grayBezel
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.imageAlignment = .alignCenter
            label.alignment = .center
            layoutView.addSubview(iv)
            layoutView.addSubview(label)
        }

        layoutView.addSubview(rangeHint)

        // 3 · 输出
        layoutView.addSubview(sec3Label)

        outModeSeg.segmentCount = 2
        outModeSeg.setLabel("相对源文件", forSegment: 0)
        outModeSeg.setLabel("绝对路径", forSegment: 1)
        outModeSeg.selectedSegment = 0
        outModeSeg.segmentStyle = .rounded
        outModeSeg.target = self
        outModeSeg.action = #selector(outModeChanged)
        layoutView.addSubview(outModeSeg)

        outField.placeholderString = "trimmed"
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

        // 4 · 裁剪方式
        layoutView.addSubview(sec4Label)

        fastRadio.setButtonType(.radio)
        fastRadio.title = "快速（不重编码）"
        fastRadio.font = NSFont.systemFont(ofSize: 12)
        fastRadio.target = self
        fastRadio.action = #selector(modeChanged)
        layoutView.addSubview(fastRadio)

        exactRadio.setButtonType(.radio)
        exactRadio.title = "精确（重编码）"
        exactRadio.font = NSFont.systemFont(ofSize: 12)
        exactRadio.target = self
        exactRadio.action = #selector(modeChanged)
        layoutView.addSubview(exactRadio)

        qualitySlider.minValue = 10
        qualitySlider.maxValue = 90
        qualitySlider.doubleValue = 55
        qualitySlider.isContinuous = true
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged)
        layoutView.addSubview(qualitySlider)

        layoutView.addSubview(qualityValue)
        layoutView.addSubview(modeHint)

        // 5 · 待裁剪文件（列表本身就是拖入区）
        layoutView.addSubview(sec5Label)

        filesCount.alignment = .right
        layoutView.addSubview(filesCount)

        addFilesBtn.target = self
        addFilesBtn.action = #selector(chooseVideos)
        layoutView.addSubview(addFilesBtn)

        removeSelBtn.target = self
        removeSelBtn.action = #selector(deleteSelectedJobs)
        layoutView.addSubview(removeSelBtn)

        jobTable.emptyHint = "把要裁剪的视频拖到这里"
        jobTable.emptySubHint = "支持多选、多目录与整个文件夹；所有文件套用同一段范围"
        jobTable.onDropPaths = { [weak self] paths in self?.addPaths(paths) }
        jobTable.onSelectionChanged = { [weak self] in self?.refreshAll() }
        jobTable.onDeleteRequested = { [weak self] in self?.deleteSelectedJobs() }

        layoutView.addSubview(jobTable.scrollView)

        // 底部
        actionBar.setStartTitle("开始裁剪")
        actionBar.addToView(layoutView)
        actionBar.onStart = { [weak self] in self?.startTrim() }
        actionBar.onStop = { [weak self] in self?.stopTrim() }
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

        // 1 · 源视频（只有一行信息；拖入统一走下面的列表）
        DITPlaceSection(sec1Label, &y, x, w)
        DITFrame(srcInfoLabel, x, y, w, 14)
        y += 14 + 14

        // 2 · 裁剪范围
        DITPlaceSection(sec2Label, &y, x, w)
        DITFrame(startLabel, x, y + 3, 32, 18)
        DITFrame(startField, x + 36, y, 150, 24)
        DITFrame(endLabel, x + 200, y + 3, 32, 18)
        DITFrame(endField, x + 236, y, 150, 24)
        // 「用完整时长」按钮靠右摆，片段长度标签必须在它左边收住 ——
        // 否则「超出源时长」那句提示会被按钮压掉一半
        let fullBtnW: CGFloat = 110.0, fullBtnX = x + w - fullBtnW, lenX = x + 394
        DITFrame(lenLabel, lenX, y + 3, max(60.0, fullBtnX - 8 - lenX), 18)
        DITFrame(fullRangeBtn, fullBtnX, y, fullBtnW, 24)
        y += 24 + 10

        // 两个画面预览并排
        let thumbW = min(200.0, (w - 12) / 2)
        let thumbH = round(thumbW * 9.0 / 16.0)
        DITFrame(startThumb, x, y, thumbW, thumbH)
        DITFrame(endThumb, x + thumbW + 12, y, thumbW, thumbH)
        y += thumbH + 4
        DITFrame(startThumbLabel, x, y, thumbW, 14)
        DITFrame(endThumbLabel, x + thumbW + 12, y, thumbW, 14)
        y += 14 + 8

        DITFrame(rangeHint, x, y, w, 14)
        y += 14 + 14

        // 3 · 输出
        DITPlaceSection(sec3Label, &y, x, w)
        DITFrame(outModeSeg, x, y, 280, 24)
        y += 24 + 8
        let btnW: CGFloat = 88
        DITFrame(outField, x, y, w - btnW - 8, 24)
        DITFrame(outChooseBtn, x + w - btnW, y, btnW, 24)
        y += 24 + 4
        DITFrame(outHintLabel, x, y, w, 14)
        y += 14 + 14

        // 4 · 裁剪方式
        DITPlaceSection(sec4Label, &y, x, w)
        let cy = y
        DITFrame(fastRadio, x, cy, 150, 20)
        DITFrame(exactRadio, x + 158, cy, 150, 20)
        DITFrame(qualitySlider, x + 316, cy + 1, 110, 22)
        DITFrame(qualityValue, x + 432, cy + 2, 28, 18)
        DITFrame(modeHint, x + 464, cy + 3, w - 464, 16)
        y += 24 + 12

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

        let mode = d.integer(forKey: "trim.outMode")
        outModeSeg.selectedSegment = (mode == 1) ? 1 : 0
        let outVal = d.string(forKey: "trim.outValue") ?? ""
        outField.stringValue = outVal.isEmpty ? "trimmed" : outVal

        var conf = d.integer(forKey: "trim.conflict")
        if conf < 0 || conf > 2 { conf = 0 }
        conflictIndex = conf

        var conc = d.integer(forKey: "trim.concurrency")
        if conc <= 0 { conc = 4 }
        concurrency = conc

        var q = d.integer(forKey: "trim.quality")
        if q <= 0 { q = 55 }
        qualitySlider.doubleValue = Double(q)
        qualityValue.stringValue = "\(q)"

        let fast = d.object(forKey: "trim.fastCopy") != nil ? d.bool(forKey: "trim.fastCopy") : true
        fastRadio.state = fast ? .on : .off
        exactRadio.state = fast ? .off : .on

        var s = d.string(forKey: "trim.start")
        var e = d.string(forKey: "trim.end")
        // 自检 / 截图预览时可用环境变量注入起止时间码，避免污染用户偏好
        let env = ProcessInfo.processInfo.environment
        if let sEnv = env["DITKIT_TRIM_START"] { s = sEnv }
        if let eEnv = env["DITKIT_TRIM_END"] { e = eEnv }
        startField.stringValue = (s?.isEmpty == false) ? s! : "00:00:00.000"
        endField.stringValue = (e?.isEmpty == false) ? e! : "00:00:10.000"

        outModeChanged()
        modeChanged()
        updateLengthLabel()
    }

    @objc private func saveDefaults() {
        let d = UserDefaults.standard
        d.set(outModeSeg.selectedSegment, forKey: "trim.outMode")
        d.set(outField.stringValue, forKey: "trim.outValue")
        d.set(conflictIndex, forKey: "trim.conflict")
        d.set(concurrency, forKey: "trim.concurrency")
        d.set(Int(qualitySlider.doubleValue), forKey: "trim.quality")
        d.set(fastRadio.state == .on, forKey: "trim.fastCopy")
        d.set(startField.stringValue, forKey: "trim.start")
        d.set(endField.stringValue, forKey: "trim.end")
    }

    // MARK: 交互

    @objc private func outModeChanged() {
        let absolute = (outModeSeg.selectedSegment == 1)
        outChooseBtn.isEnabled = absolute
        if absolute {
            outField.placeholderString = "/Users/you/Movies/trimmed"
            outHintLabel.stringValue = "带 ~ 会自动展开；目录不存在会自动创建"
        } else {
            outField.placeholderString = "trimmed"
            outHintLabel.stringValue = "相对每个源文件所在目录；填 . 表示输出到源文件同目录"
        }
        saveDefaults()
    }

    @objc private func modeChanged() {
        let fast = (fastRadio.state == .on)
        if fast {
            exactRadio.state = .off
        } else {
            fastRadio.state = .off
        }
        qualitySlider.isEnabled = !fast
        qualityValue.textColor = fast ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor
        modeHint.stringValue = fast
            ? "秒级完成，但起点会吸附到最近的关键帧（可能前后差几秒）"
            : "逐帧重编码，切点精确到帧；音频会重编码为 AAC 192k"
        saveDefaults()
    }

    @objc private func qualityChanged() {
        qualityValue.stringValue = "\(Int(qualitySlider.doubleValue))"
        saveDefaults()
    }

    /// 输入框失焦或回车后，重新校验范围并刷新预览
    @objc func controlTextDidEndEditing(_ note: Notification) {
        rangeEdited()
    }

    @objc private func rangeEdited() {
        updateLengthLabel()
        saveDefaults()
        scheduleThumbnails()
    }

    @objc private func useFullRange() {
        if srcDuration <= 0 { NSSound.beep(); return }
        startField.stringValue = "00:00:00.000"
        endField.stringValue = DITEngine.timeStringFromSeconds(srcDuration)
        rangeEdited()
    }

    /// 解析当前范围；失败时（quiet = false）把错误写进状态栏并返回 nil
    private func currentRange(quiet: Bool) -> (start: Double, end: Double)? {
        let s = DITEngine.secondsFromTimeString(startField.stringValue)
        let e = DITEngine.secondsFromTimeString(endField.stringValue)
        if s < 0 || e < 0 {
            if !quiet { actionBar.setStatus("时间格式看不懂：请用 00:01:30.500 或 90 / 1m30s") }
            return nil
        }
        if e <= s {
            if !quiet { actionBar.setStatus("终点必须大于起点") }
            return nil
        }
        return (s, e)
    }

    private func updateLengthLabel() {
        guard let range = currentRange(quiet: true) else {
            lenLabel.stringValue = "范围无效"
            lenLabel.toolTip = nil
            lenLabel.textColor = NSColor.systemRed
            return
        }
        let s = range.start, e = range.end
        let src = DITEngine.timeStringFromSeconds(srcDuration)

        // 起点就已经在源之外：这段落不到任何画面上，长度也就无从谈起
        guard let actual = effectiveRange(start: s, end: e) else {
            lenLabel.stringValue = "片段长度 无内容"
            lenLabel.toolTip = "起点超出源时长 \(src)"
            lenLabel.textColor = NSColor.systemRed
            rangeHint.stringValue = "起点超出源时长 \(src)，这段落在源之外，成品不会有画面；时间可以写 90 / 1m30s"
            rangeHint.textColor = NSColor.systemOrange
            return
        }

        lenLabel.textColor = NSColor.secondaryLabelColor
        // 长度算的是成品真正会有的长度：终点被截断时，按输入框里那个值算出来的长度
        // 只是个请求值，照着显示会让人以为成品有那么长
        lenLabel.stringValue = "片段长度 \(DITEngine.timeStringFromSeconds(actual.end - actual.start))"

        // 「超出源时长」这句放不进长度标签 —— 那一排只给它一百多点宽，右边还杵着
        // 「用完整时长」按钮。所以警告挂在下面整行宽的提示上，并用橙色以示显眼。
        if actual.end < e - 0.0005 {
            lenLabel.toolTip = "终点超出源时长 \(src)，实际会截断到结尾"
            rangeHint.stringValue = "终点超出源时长 \(src)，成品会截断到结尾；时间可以写 90 / 1m30s"
            rangeHint.textColor = NSColor.systemOrange
        } else {
            lenLabel.toolTip = "片段长度 = 终点 − 起点"
            rangeHint.stringValue = DITRangeHintText()
            rangeHint.textColor = NSColor.secondaryLabelColor
        }
    }

    // MARK: 画面预览

    private func scheduleThumbnails() {
        guard let srcPath, !srcPath.isEmpty else {
            startThumb.image = nil
            endThumb.image = nil
            startThumbLabel.stringValue = "起点画面"
            endThumbLabel.stringValue = "终点画面"
            return
        }
        guard let range = currentRange(quiet: true) else { return }
        let actual = effectiveRange(start: range.start, end: range.end)

        // 抽帧偏右一点点，避免正好落在黑帧/转场帧上
        thumbToken += 1
        let token = thumbToken
        if let actual {
            extractFrame(at: actual.start + 0.04, slot: 0, token: token)
            extractFrame(at: max(actual.start + 0.04, actual.end - 0.04), slot: 1, token: token)
        } else {
            // 整段都在源之外，没有画面可抽
            startThumb.image = nil
            endThumb.image = nil
        }

        // 标签跟着成品实际落到的位置走。照抄输入框里的值会出现「终点 00:00:20.000」
        // 配一个空框、而旁边提示又说「成品会截断到结尾」这种互相打架的三方说法。
        if let actual {
            startThumbLabel.stringValue = "起点 \(DITEngine.timeStringFromSeconds(actual.start))"
            let mark = actual.end < range.end - 0.0005 ? "（源结尾）" : ""
            endThumbLabel.stringValue = "终点 \(DITEngine.timeStringFromSeconds(actual.end))\(mark)"
        } else {
            startThumbLabel.stringValue = "起点 \(DITEngine.timeStringFromSeconds(range.start))（源之外）"
            endThumbLabel.stringValue = "终点 \(DITEngine.timeStringFromSeconds(range.end))（源之外）"
        }
    }

    /// 成品实际会落到的范围：与源内容取交集。
    ///
    /// 终点超出源时长时 ffmpeg 会自然截断到结尾，所以实际终点就是源时长；
    /// 起点就已经在源之外时根本没有内容可截，返回 nil。
    /// 源时长还没探到时不做任何收缩 —— 宁可照抄填的值，也不猜。
    private func effectiveRange(start: Double, end: Double) -> (start: Double, end: Double)? {
        guard srcDuration > 0 else { return (start, end) }
        if start >= srcDuration { return nil }
        return (start, min(end, srcDuration))
    }

    private func extractFrame(at t: Double, slot: Int, token: Int) {
        guard let ffmpeg = DITEngine.resolveTool("ffmpeg") else { return }
        let input = srcPath ?? ""
        let out = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            String(format: "ditkit-thumb-%ld-%ld.png", slot, token))

        // 抽帧是 IO + 解码，放到后台，避免拖住界面
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 时间段超出源时长时，ffmpeg 不产出文件却仍退出 0 —— 不先删掉同名旧图，
            // 下面就会把残留文件当成这次的取帧结果。
            try? FileManager.default.removeItem(atPath: out)

            let task = Process()
            task.executableURL = URL(fileURLWithPath: ffmpeg)
            task.arguments = ["-hide_banner", "-loglevel", "error",
                              "-ss", String(format: "%.3f", max(0.0, t)),
                              "-i", input,
                              "-frames:v", "1",
                              "-vf", "scale=440:-2",
                              "-y", out]
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
            // 文件真的落地了才算成功
            if ok && !FileManager.default.fileExists(atPath: out) { ok = false }

            DispatchQueue.main.async {
                guard let self else { return }
                if self.thumbToken != token { return }   // 已经有更新的请求了
                let iv = (slot == 0) ? self.startThumb : self.endThumb
                iv.image = ok ? NSImage(contentsOfFile: out) : nil
            }
        }
    }

    // MARK: 文件管理

    func addInputPaths(_ paths: [String]) {
        addPaths(paths)
    }

    func beginRun() {
        startTrim()
    }

    func beginStop() {
        stopTrim()
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
            actionBar.setStatus("没有识别到可处理的视频文件（支持 mp4 / mov / mkv / mxf …）")
        }

        // 第一个文件用来取媒体信息与画面预览
        refreshSourceInfo()
        jobTable.reloadAll()
        refreshAll()
        scheduleThumbnails()
    }

    private func refreshSourceInfo() {
        guard let first = jobTable.jobs.first else {
            srcPath = nil
            srcDuration = 0
            srcInfoLabel.stringValue = "还没有选择文件 —— 把视频拖到下面的列表，或点「添加文件…」"
            srcInfoLabel.textColor = NSColor.tertiaryLabelColor
            startThumb.image = nil
            endThumb.image = nil
            startThumbLabel.stringValue = "起点画面"
            endThumbLabel.stringValue = "终点画面"
            return
        }
        srcPath = first.inputPath
        srcDuration = DITEngine.probeDuration(first.inputPath)
        let summary = DITEngine.probeSummary(first.inputPath)

        var s = "\(first.displayName)"
        if srcDuration > 0 {
            s += "　·　时长 \(DITEngine.timeStringFromSeconds(srcDuration))"
        }
        if let summary, !summary.isEmpty { s += "　·　\(summary)" }
        if jobTable.jobs.count > 1 {
            s += "　·　共 \(jobTable.jobs.count) 个文件，预览取第一个"
        }
        srcInfoLabel.stringValue = s
        srcInfoLabel.textColor = NSColor.secondaryLabelColor

        // 首次拿到时长时，把终点默认值设为 10 秒或整段（取短的那个）
        if srcDuration > 0 && endField.stringValue == "00:00:10.000" && srcDuration < 10.0 {
            endField.stringValue = DITEngine.timeStringFromSeconds(srcDuration)
        }
        updateLengthLabel()
    }

    @objc private func chooseVideos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "选择要裁剪的视频或文件夹"
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
        o.suffix = "_trim"
        return o
    }

    private func buildSpec() -> DITTrimSpec? {
        guard let range = currentRange(quiet: true) else { return nil }
        let spec = DITTrimSpec()
        spec.startSec = range.start
        spec.endSec = range.end
        spec.fastCopy = (fastRadio.state == .on)
        spec.quality = Int(qualitySlider.doubleValue)
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

    func simulateColumnResize(_ index: Int, delta: CGFloat) {
        jobTable.simulateColumnResize(index, delta: delta)
    }

    /// 只把条目从列表里去掉，不动磁盘上的文件
    @objc func deleteSelectedJobs() {
        if engine?.isRunning ?? false { NSSound.beep(); return }
        let n = jobTable.removeSelectedJobs()
        if n == 0 { NSSound.beep(); return }
        actionBar.setStatus("已从列表移除 \(n) 个（磁盘上的文件不受影响）")
        // 取样的第一个文件可能正好被删掉了，源信息与画面预览都要跟着刷新
        refreshSourceInfo()
        scheduleThumbnails()
        refreshAll()
    }

    @objc private func startTrim() {
        if engine?.isRunning ?? false { return }
        if jobTable.jobs.isEmpty {
            NSSound.beep()
            actionBar.setStatus("还没有拖入视频")
            return
        }
        guard let spec = buildSpec() else { return }
        if spec.duration < 0.04 {
            actionBar.setStatus("片段太短了（至少约 1 帧）")
            return
        }

        let o = buildOptions()
        let engine = DITEngine(jobs: jobTable.jobs, output: o) { job, _ in
            DITTrimArguments(job, spec)
        }

        // 进度分母是片段长度，不是源文件总时长。终点超出某个文件的时长时，那个文件
        // 实际只会截到结尾 —— 分母要是照抄请求长度，进度条走到一半就直接跳完成。
        // 所以现探一次源时长：每个文件一趟 ffprobe，代价远小于把进度算错。
        engine.expectedDuration = { job in
            let d = DITEngine.probeDuration(job.inputPath)
            guard d > 0, spec.endSec > d else { return spec.duration }
            return max(0.0, d - spec.startSec)
        }

        engine.onJobUpdate = { [weak self] job in self?.jobUpdated(job) }
        engine.onFinished = { [weak self] in self?.allFinished() }

        if let err = engine.start() {
            let a = NSAlert()
            a.messageText = "无法开始裁剪"
            a.informativeText = err
            a.alertStyle = .warning
            a.runModal()
            return
        }
        self.engine = engine
        refreshAll()
    }

    @objc private func stopTrim() {
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
        fullRangeBtn.isEnabled = !running && (srcDuration > 0)
        fastRadio.isEnabled = !running
        exactRadio.isEnabled = !running
        qualitySlider.isEnabled = !running && (fastRadio.state != .on)
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
        用法: DITKit --cli --trim --start <起点> --end <终点> [选项] -- <视频文件...>
        选项:
          --start <时间>          片段起点，默认 00:00:00.000
          --end <时间>            片段终点（必填）
          --fast / --exact        快速流复制（默认）或精确重编码
          --quality <10-90>       精确模式下的编码质量，默认 55
          --out <绝对目录>        输出到指定目录
          --relative <子目录>     输出到每个源文件所在目录的子目录（默认 trimmed）
          --jobs <N>              最大并发，默认 4
          --conflict <skip|overwrite|rename>  命名冲突策略，默认 skip
          --suffix <后缀>         输出文件名后缀，默认 _trim
        时间可以写 00:01:30.500，也可以写 90 / 1m30s

        """
    }

    /// --cli 模式入口，返回进程退出码
    static func runCLI(_ argv: [String]) -> Int32 {
        let o = DITOutputOptions()
        o.suffix = "_trim"
        o.outValue = "trimmed"
        let spec = DITTrimSpec()
        spec.endSec = -1

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
            // --trim 只是入口用来分发到本页的标记（LUT 页同理用 --lut 携带参数），
            // 这里必须显式跳过，否则会掉进下面的「未知选项」分支直接打印用法
            if a == "--trim" { continue }
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
                }
                i += 1
            case "--fast":
                spec.fastCopy = true
            case "--exact":
                spec.fastCopy = false
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

        if spec.endSec < 0 || inputs.isEmpty {
            FileHandle.standardError.write(Data(cliUsage.utf8))
            return 2
        }
        if spec.endSec <= spec.startSec {
            FileHandle.standardError.write(Data("终点必须大于起点\n".utf8))
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

        // 摘要里的范围按「成品实际会落到的位置」打印。照抄填的终点，用户会以为成品
        // 真有那么长 —— 而超出第一个文件长度的部分会被 ffmpeg 截掉。
        // 连起点都在源之外时没有可截的位置，保持原样打印，由提示行说明不会有画面。
        let firstDur = DITEngine.probeDuration(files[0])
        let startBeyond = firstDur > 0 && spec.startSec >= firstDur
        let endBeyond = firstDur > 0 && spec.endSec > firstDur
        let shownEnd = (endBeyond && !startBeyond) ? firstDur : spec.endSec
        print("范围  : \(DITEngine.timeStringFromSeconds(spec.startSec)) → \(DITEngine.timeStringFromSeconds(shownEnd))（\(DITEngine.timeStringFromSeconds(shownEnd - spec.startSec))）")
        if startBeyond {
            print("提示  : 第一个文件只有 \(DITEngine.timeStringFromSeconds(firstDur))，起点超出其长度，这个文件不会有画面")
        } else if endBeyond {
            print("提示  : 第一个文件只有 \(DITEngine.timeStringFromSeconds(firstDur))，终点超出其长度，上面按截断后的实际范围显示")
        }
        print("方式  : \(spec.fastCopy ? "快速（流复制）" : "精确（重编码）")")
        print("文件数: \(jobs.count)   并发: \(o.maxConcurrent)")
        print("")

        let engine = DITEngine(jobs: jobs, output: o) { job, _ in
            DITTrimArguments(job, spec)
        }
        engine.expectedDuration = { _ in spec.duration }   // 命令行不显示进度，用不上这个

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
