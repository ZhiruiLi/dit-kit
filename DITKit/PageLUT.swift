//
//  PageLUT.swift —— 工具页：LUT 批量调色
//
//  这一页的活儿：把一批视频套同一个 LUT，走硬件编码输出。
//  ffmpeg 参数构造被单独抽成 DITLUTArguments()，所以 GUI 和 --cli 用的是同一份逻辑。
//

import AppKit
import UniformTypeIdentifiers

// MARK: - ffmpeg 参数

/// LUT 批处理的 ffmpeg 参数（GUI 与 --cli 共用）
func DITLUTArguments(_ job: DITJob, _ lutPath: String, _ quality: Int) -> [String] {
    var a: [String] = ["-i", job.inputPath]

    let lut = (lutPath as NSString).expandingTildeInPath
    let filter = "lut3d=file=\(DITEngine.escapeFilterValue(lut)):interp=tetrahedral"
    a += ["-vf", filter]

    a += ["-c:v", "hevc_videotoolbox",
          "-q:v", String(quality),
          "-pix_fmt", "p010le"]

    let lowExt = (job.inputPath as NSString).pathExtension.lowercased()
    if lowExt == "mp4" || lowExt == "mov" || lowExt == "m4v" {
        a += ["-tag:v", "hvc1"]
    }
    a += ["-c:a", "copy"]
    return a
}

// MARK: - LUT 文件名的判定

/// LUT 的合法后缀（ffmpeg 的 lut3d 只吃这几种）
private func DITLUTExtensions() -> [String] {
    ["cube", "3dl", "dat", "m3d"]
}

/// 按后缀名判断像不像 LUT 文件（不看文件是否存在）
private func DITIsLUTPath(_ path: String) -> Bool {
    let ext = (path as NSString).pathExtension.lowercased()
    return !ext.isEmpty && DITLUTExtensions().contains(ext)
}

/// 从一批路径里挑出第一个像 LUT 的（大小写不敏感）
private func DITFirstLUTPath(_ paths: [String]) -> String? {
    for p in paths where DITIsLUTPath(p) { return p }
    return nil
}

// MARK: - 工具页

final class PageLUT: NSObject, DITToolPage {

    // 控件全部先建好、再在 buildControls() 里接线（target/action 与 addSubview）。
    // 这样能用 let 而不是一堆隐式解包可选值，同时在 init 里也拿得到 self。
    private let layoutView = LayoutView(frame: NSRect(x: 0, y: 0, width: 740, height: 600))

    private let sec1Label = DITSectionLabel("1 · LUT 文件")
    private let sec2Label = DITSectionLabel("2 · 输出目录")
    private let sec3Label = DITSectionLabel("3 · 转换设置")
    private let sec4Label = DITSectionLabel("4 · 待转换文件")

    private let c1Label = DITLabel("最大并发", 12, false)
    private let c2Label = DITLabel("命名冲突", 12, false)
    private let c3Label = DITLabel("编码质量", 12, false)
    private let qualityHint = DITLabel("越大越清晰", 11, false)
    private let lutWell = DropWellView(frame: .zero)

    private let outModeSeg = NSSegmentedControl(frame: .zero)
    private let outField = NSTextField(frame: .zero)
    private let outChooseBtn = NSButton(frame: .zero)
    private let outHintLabel = DITLabel("", 11, false)

    private let concValue = NSTextField(frame: .zero)
    private let concStepper = NSStepper(frame: .zero)
    private let conflictPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualitySlider = NSSlider(frame: .zero)
    private let qualityValue = DITLabel("55", 12, false)

    private let filesCount = DITLabel("", 11, false)
    private let addFilesBtn = DITButton("添加文件…", nil, nil)
    private let removeSelBtn = DITButton("删除选中", nil, nil)
    private let jobTable = DITJobTable()
    private let actionBar = DITActionBar()

    private var engine: DITEngine?
    private var lutPath: String?
    /// 已点击停止、等引擎收尾；期间不让进度行覆盖提示
    private var stopping = false
    private var lastOutputDir: String?

    override init() {
        super.init()
        buildControls()
        loadDefaults()
        refreshAll()
    }

    // MARK: 协议

    var view: NSView { layoutView }
    var pageTitle: String { "LUT 批量调色" }
    var busy: Bool { engine?.isRunning ?? false }

    func layoutInBounds(_ bounds: NSRect) {
        doLayout()
    }

    // MARK: 构建界面

    private func buildControls() {
        layoutView.onLayout = { [weak self] in self?.doLayout() }

        // 1 · LUT 文件
        layoutView.addSubview(sec1Label)

        lutWell.caption = "把 .cube 文件拖到这里"
        lutWell.hint = "或点击此处选择　·　支持 .cube / .3dl / .dat / .m3d"
        lutWell.onPaths = { [weak self] paths in self?.setLUTFromPaths(paths) }
        lutWell.onClick = { [weak self] in self?.chooseLUT() }
        // 后缀名不对（比如顺手拖进来一个视频）就当场拒收，并说明原因
        lutWell.willAcceptPaths = { [weak self] paths in
            if DITFirstLUTPath(paths) != nil { return true }
            self?.reportRejectedLUT(paths)
            return false
        }
        layoutView.addSubview(lutWell)

        // 2 · 输出目录
        layoutView.addSubview(sec2Label)

        outModeSeg.segmentCount = 2
        outModeSeg.setLabel("相对源文件", forSegment: 0)
        outModeSeg.setLabel("绝对路径", forSegment: 1)
        outModeSeg.selectedSegment = 0
        outModeSeg.segmentStyle = .rounded
        outModeSeg.target = self
        outModeSeg.action = #selector(outModeChanged)
        layoutView.addSubview(outModeSeg)

        outField.placeholderString = "graded"
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

        // 3 · 转换设置
        layoutView.addSubview(sec3Label)
        layoutView.addSubview(c1Label)

        concValue.alignment = .center
        concValue.isEditable = false
        concValue.isBezeled = true
        concValue.font = NSFont.systemFont(ofSize: 12)
        layoutView.addSubview(concValue)

        concStepper.minValue = 1
        concStepper.maxValue = 16
        concStepper.increment = 1
        concStepper.valueWraps = false
        concStepper.target = self
        concStepper.action = #selector(concChanged)
        layoutView.addSubview(concStepper)

        layoutView.addSubview(c2Label)

        conflictPopup.addItems(withTitles: ["跳过", "覆盖", "自动加序号"])
        conflictPopup.font = NSFont.systemFont(ofSize: 12)
        conflictPopup.target = self
        conflictPopup.action = #selector(saveDefaults)
        layoutView.addSubview(conflictPopup)

        layoutView.addSubview(c3Label)

        qualitySlider.minValue = 10
        qualitySlider.maxValue = 90
        qualitySlider.doubleValue = 55
        qualitySlider.isContinuous = true
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged)
        layoutView.addSubview(qualitySlider)

        layoutView.addSubview(qualityValue)
        layoutView.addSubview(qualityHint)

        // 4 · 待转换文件（列表本身就是拖入区）
        layoutView.addSubview(sec4Label)

        filesCount.alignment = .right
        layoutView.addSubview(filesCount)

        addFilesBtn.target = self
        addFilesBtn.action = #selector(chooseVideos)
        layoutView.addSubview(addFilesBtn)

        removeSelBtn.target = self
        removeSelBtn.action = #selector(deleteSelectedJobs)
        layoutView.addSubview(removeSelBtn)

        jobTable.emptyHint = "把视频拖到这里"
        jobTable.emptySubHint = "支持多选、多目录，也可以整个文件夹拖进来"
        jobTable.onDropPaths = { [weak self] paths in self?.addPaths(paths) }
        jobTable.onSelectionChanged = { [weak self] in self?.refreshAll() }
        jobTable.onDeleteRequested = { [weak self] in self?.deleteSelectedJobs() }

        layoutView.addSubview(jobTable.scrollView)

        // 底部
        actionBar.setStartTitle("开始转换")
        actionBar.addToView(layoutView)
        actionBar.onStart = { [weak self] in self?.startConversion() }
        actionBar.onStop = { [weak self] in self?.stopConversion() }
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

        // 1 · LUT
        DITPlaceSection(sec1Label, &y, x, w)
        DITFrame(lutWell, x, y, w, 48)
        y += 48 + 14

        // 2 · 输出
        DITPlaceSection(sec2Label, &y, x, w)
        DITFrame(outModeSeg, x, y, 280, 24)
        y += 24 + 8
        let btnW: CGFloat = 88
        DITFrame(outField, x, y, w - btnW - 8, 24)
        DITFrame(outChooseBtn, x + w - btnW, y, btnW, 24)
        y += 24 + 4
        DITFrame(outHintLabel, x, y, w, 14)
        y += 14 + 14

        // 3 · 设置
        DITPlaceSection(sec3Label, &y, x, w)
        let cy = y
        DITFrame(c1Label, x, cy + 2, 56, 18)
        DITFrame(concValue, x + 58, cy + 1, 40, 21)
        DITFrame(concStepper, x + 100, cy, 19, 22)
        DITFrame(c2Label, x + 150, cy + 2, 56, 18)
        DITFrame(conflictPopup, x + 208, cy, 130, 24)
        DITFrame(c3Label, x + 366, cy + 2, 56, 18)
        DITFrame(qualitySlider, x + 424, cy + 1, 110, 22)
        DITFrame(qualityValue, x + 540, cy + 2, 28, 18)
        DITFrame(qualityHint, x + 572, cy + 4, 132, 14)
        y += 26 + 14

        // 4 · 文件（标题行右边放「添加文件…／删除选中」，计数贴左）
        let rh: CGFloat = 24.0
        DITFrame(sec4Label, x, y + 4, w * 0.4, 16)
        let bw2: CGFloat = 92.0, bgap: CGFloat = 8.0
        DITFrame(removeSelBtn, x + w - bw2, y, bw2, rh)
        DITFrame(addFilesBtn, x + w - bw2 * 2 - bgap, y, bw2, rh)
        DITFrame(filesCount, x + w * 0.4, y + 6, w * 0.6 - bw2 * 2 - bgap - 8, 14)
        y += rh + 8

        // 底部操作栏
        let tableBottom = actionBar.layoutFromBottom(H - PAD, x: x, width: w)

        // 表格填满剩余空间
        jobTable.layoutColumnsForWidth(w)
        DITFrame(jobTable.scrollView, x, y, w, max(60, tableBottom - y))
    }

    // MARK: 偏好

    private func loadDefaults() {
        let d = UserDefaults.standard
        // 自检 / 截图预览时可用环境变量注入 LUT，避免污染用户偏好
        let lutEnv = ProcessInfo.processInfo.environment["DITKIT_LUT"]
        let saved = d.string(forKey: "lut.lutPath")
        let lut = lutEnv ?? saved ?? ""
        if !lut.isEmpty && FileManager.default.fileExists(atPath: lut) {
            lutPath = lut
        } else {
            lutPath = nil
        }
        applyLUTDisplay()

        let mode = d.integer(forKey: "lut.outMode")
        outModeSeg.selectedSegment = (mode == 1) ? 1 : 0
        let outVal = d.string(forKey: "lut.outValue") ?? ""
        outField.stringValue = outVal.isEmpty ? "graded" : outVal

        var conc = d.integer(forKey: "lut.concurrency")
        if conc <= 0 { conc = 4 }
        concStepper.integerValue = conc
        concValue.stringValue = "\(conc)"

        var conf = d.integer(forKey: "lut.conflict")
        if conf < 0 || conf > 2 { conf = 0 }
        conflictPopup.selectItem(at: conf)

        var q = d.integer(forKey: "lut.quality")
        if q <= 0 { q = 55 }
        qualitySlider.doubleValue = Double(q)
        qualityValue.stringValue = "\(q)"

        outModeChanged()
    }

    @objc private func saveDefaults() {
        let d = UserDefaults.standard
        if let lutPath, !lutPath.isEmpty {
            d.set(lutPath, forKey: "lut.lutPath")
        } else {
            d.removeObject(forKey: "lut.lutPath")
        }
        d.set(outModeSeg.selectedSegment, forKey: "lut.outMode")
        d.set(outField.stringValue, forKey: "lut.outValue")
        d.set(concStepper.integerValue, forKey: "lut.concurrency")
        d.set(conflictPopup.indexOfSelectedItem, forKey: "lut.conflict")
        d.set(Int(qualitySlider.doubleValue), forKey: "lut.quality")
    }

    // MARK: 交互

    private func applyLUTDisplay() {
        if let lutPath, !lutPath.isEmpty {
            lutWell.caption = (lutPath as NSString).lastPathComponent
            lutWell.hint = lutPath
        } else {
            lutWell.caption = "把 .cube 文件拖到这里"
            lutWell.hint = "或点击此处选择　·　支持 .cube / .3dl / .dat / .m3d"
        }
    }

    /// 拖进来的东西里一个 LUT 都没有 —— 把第一个不合格的说出来，别让人以为拖成功了
    private func reportRejectedLUT(_ paths: [String]) {
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
            actionBar.setStatus("LUT 需要一个文件，不能是文件夹")
        } else {
            actionBar.setStatus("「\(name)」不是 LUT 文件，只接受 .cube / .3dl / .dat / .m3d")
        }
    }

    private func setLUTFromPaths(_ paths: [String]) {
        if paths.isEmpty { return }

        // 一次拖进来多个文件时，挑第一个像 LUT 的
        guard let candidate = DITFirstLUTPath(paths) else {
            reportRejectedLUT(paths)
            return
        }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir) || isDir.boolValue {
            reportRejectedLUT(paths)
            return
        }

        lutPath = candidate
        applyLUTDisplay()
        saveDefaults()
        refreshAll()
    }

    /// 自检用：把「拖动进入 → 落点」这两步都走一遍，并把结论打到标准输出
    func simulateLUTDrop(_ paths: [String]) -> Bool {
        let accepted = lutWell.willAcceptPaths?(paths) ?? true
        let name = paths.first.map { ($0 as NSString).lastPathComponent } ?? ""
        print("LUT 拖入: \(accepted ? "接受" : "拒绝")  \(name)")
        fflush(stdout)
        if accepted { lutWell.onPaths?(paths) }
        return accepted
    }

    @objc private func chooseLUT() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 LUT 文件"
        var types: [UTType] = []
        for ext in ["cube", "3dl", "dat", "m3d", "CUBE"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        if !types.isEmpty { panel.allowedContentTypes = types }
        if panel.runModal() == .OK, let url = panel.url {
            setLUTFromPaths([url.path])
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

    @objc private func chooseVideos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "选择视频文件或文件夹"
        if panel.runModal() == .OK {
            addPaths(panel.urls.map(\.path))
        }
    }

    private func buildOptions() -> DITOutputOptions {
        let o = DITOutputOptions()
        o.outMode = (outModeSeg.selectedSegment == 1) ? .absolute : .relativeToSource
        o.outValue = outField.stringValue
        o.maxConcurrent = concStepper.integerValue
        o.conflict = [.skip, .overwrite, .rename][max(0, min(2, conflictPopup.indexOfSelectedItem))]
        o.suffix = "_graded"
        return o
    }

    @objc private func outModeChanged() {
        let absolute = (outModeSeg.selectedSegment == 1)
        outChooseBtn.isEnabled = absolute
        if absolute {
            outField.placeholderString = "/Users/you/Movies/graded"
            outHintLabel.stringValue = "带 ~ 会自动展开；目录不存在会自动创建"
        } else {
            outField.placeholderString = "graded"
            outHintLabel.stringValue = "相对每个源文件所在目录；填 . 表示输出到源文件同目录"
        }
        saveDefaults()
    }

    @objc private func concChanged() {
        concValue.stringValue = "\(concStepper.integerValue)"
        saveDefaults()
    }

    @objc private func qualityChanged() {
        qualityValue.stringValue = "\(Int(qualitySlider.doubleValue))"
        saveDefaults()
    }

    // MARK: 任务管理

    func addInputPaths(_ paths: [String]) {
        addPaths(paths)
    }

    func beginRun() {
        startConversion()
    }

    func beginStop() {
        stopConversion()
    }

    func statusLine() -> String {
        actionBar.statusText
    }

    private func addPaths(_ paths: [String]) {
        if engine?.isRunning ?? false {
            NSSound.beep()
            return
        }
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
        refreshAll()
    }

    @objc private func clearJobs() {
        if engine?.isRunning ?? false { NSSound.beep(); return }
        jobTable.jobs.removeAll()
        jobTable.reloadAll()
        actionBar.setProgress(0)
        actionBar.setStatus("就绪")
        refreshAll()
    }

    func selectAllJobs() {
        jobTable.selectAllJobs()
    }

    /// 只把条目从列表里去掉，不动磁盘上的文件
    @objc func deleteSelectedJobs() {
        if engine?.isRunning ?? false { NSSound.beep(); return }
        let n = jobTable.removeSelectedJobs()
        if n == 0 { NSSound.beep(); return }
        actionBar.setStatus("已从列表移除 \(n) 个（磁盘上的文件不受影响）")
        refreshAll()
    }

    func simulateColumnResize(_ index: Int, delta: CGFloat) {
        jobTable.simulateColumnResize(index, delta: delta)
    }

    @objc private func startConversion() {
        if engine?.isRunning ?? false { return }
        let o = buildOptions()

        let lut = lutPath ?? ""
        let quality = Int(qualitySlider.doubleValue)
        let engine = DITEngine(jobs: jobTable.jobs, output: o) { job, _ in
            DITLUTArguments(job, lut, quality)
        }

        engine.preflight = {
            if lut.isEmpty { return "还没有指定 LUT 文件" }
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: lut, isDirectory: &isDir) || isDir.boolValue {
                return "LUT 文件不存在：\(lut)"
            }
            return nil
        }
        engine.onJobUpdate = { [weak self] job in self?.jobUpdated(job) }
        engine.onFinished = { [weak self] in self?.allFinished() }

        if let err = engine.start() {
            let a = NSAlert()
            a.messageText = "无法开始转换"
            a.informativeText = err
            a.alertStyle = .warning
            a.runModal()
            return
        }
        self.engine = engine
        refreshAll()
    }

    @objc private func stopConversion() {
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
        lutWell.enabled = !running
        jobTable.dropEnabled = !running
        addFilesBtn.isEnabled = !running
        removeSelBtn.isEnabled = !running && jobTable.hasSelection
        outField.isEnabled = !running
        outModeSeg.isEnabled = !running
        outChooseBtn.isEnabled = !running && (outModeSeg.selectedSegment == 1)
        conflictPopup.isEnabled = !running
        concStepper.isEnabled = !running
        qualitySlider.isEnabled = !running
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
        用法: DITKit --cli --lut <LUT文件> [选项] -- <视频文件...>
        选项:
          --out <绝对目录>        输出到指定目录
          --relative <子目录>     输出到每个源文件所在目录的子目录（默认 graded）
          --jobs <N>              最大并发，默认 4
          --conflict <skip|overwrite|rename>  命名冲突策略，默认 skip
          --quality <10-90>       编码质量，默认 55
          --suffix <后缀>         输出文件名后缀，默认 _graded

        """
    }

    /// --cli 模式入口，返回进程退出码
    static func runCLI(_ argv: [String]) -> Int32 {
        let o = DITOutputOptions()
        o.suffix = "_graded"
        o.outValue = "graded"
        var inputs: [String] = []
        var lutPath: String?
        var quality = 55
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
            /// 取下一个位置的值（已经到末尾就返回 nil）
            func nextValue() -> String? { i < argv.count ? argv[i] : nil }

            switch a {
            case "--lut":
                lutPath = nextValue()
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
            case "--quality":
                if let v = nextValue() { quality = (v as NSString).integerValue }
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

        if (lutPath ?? "").isEmpty || inputs.isEmpty {
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

        let lut = lutPath ?? ""
        print("LUT   : \(lut)")
        print("文件数: \(jobs.count)   并发: \(o.maxConcurrent)")
        print("")

        let engine = DITEngine(jobs: jobs, output: o) { job, _ in
            DITLUTArguments(job, lut, quality)
        }
        engine.preflight = {
            if lut.isEmpty { return "还没有指定 LUT 文件" }
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: lut, isDirectory: &isDir) || isDir.boolValue {
                return "LUT 文件不存在：\(lut)"
            }
            return nil
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
