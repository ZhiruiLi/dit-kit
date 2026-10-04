//
//  DITUI.swift —— DITKit 共享界面零件
//
//  把 DropWellView / LayoutView / 控件工厂 / 任务表格 / 底部操作栏 抽出来，
//  让每个工具页（LUT 批量调色、视频裁剪 …）只关心自己特有的控件。
//
//  视图类名与列宽会出现在自检诊断里被测试断言，改名要同步改测试。
//

import AppKit

// MARK: - 公共小工具

/// 从拖放剪贴板里取出文件路径（只要文件 URL）
func DITFilePathsFromPasteboard(_ pb: NSPasteboard?) -> [String] {
    guard let pb else { return [] }
    let urls = pb.readObjects(forClasses: [NSURL.self],
                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    return urls.compactMap { $0.path.isEmpty ? nil : $0.path }
}

/// 在视图中央画「主句 + 副句」两行居中文字。
/// 按视图自身的翻转方向摆放，所以翻转容器和非翻转容器里都能画正。
func DITDrawHintText(_ v: NSView, _ caption: String?, _ hint: String?,
                     _ captionAttrs: [NSAttributedString.Key: Any],
                     _ hintAttrs: [NSAttributedString.Key: Any]) {
    let c = caption ?? ""
    let h = hint ?? ""
    if c.isEmpty { return }

    let cs = NSAttributedString(string: c, attributes: captionAttrs).size()
    let hs = h.isEmpty ? NSSize.zero : NSAttributedString(string: h, attributes: hintAttrs).size()
    let gap: CGFloat = h.isEmpty ? 0 : 3.0
    let blockH = cs.height + (h.isEmpty ? 0 : hs.height + gap)
    let midX = v.bounds.midX
    let base = v.bounds.midY - blockH / 2.0

    // draw(at:) 的点在非翻转坐标系里是文字左下角、在翻转坐标系里是左上角
    if v.isFlipped {
        (c as NSString).draw(at: NSPoint(x: midX - cs.width / 2.0, y: base), withAttributes: captionAttrs)
        if !h.isEmpty {
            (h as NSString).draw(at: NSPoint(x: midX - hs.width / 2.0, y: base + cs.height + gap),
                                 withAttributes: hintAttrs)
        }
    } else {
        if !h.isEmpty {
            (h as NSString).draw(at: NSPoint(x: midX - hs.width / 2.0, y: base), withAttributes: hintAttrs)
            (c as NSString).draw(at: NSPoint(x: midX - cs.width / 2.0, y: base + hs.height + gap),
                                 withAttributes: captionAttrs)
        } else {
            (c as NSString).draw(at: NSPoint(x: midX - cs.width / 2.0, y: base), withAttributes: captionAttrs)
        }
    }
}

// MARK: - 拖放区

/// 虚线拖放区：可接住文件/文件夹拖入，也可点击触发选择
final class DropWellView: NSView {

    var caption = "" { didSet { needsDisplay = true } }
    var hint = "" { didSet { needsDisplay = true } }
    var highlight = false { didSet { needsDisplay = true } }
    var enabled = true

    var onPaths: (([String]) -> Void)?
    var onClick: (() -> Void)?
    /// 可选的接收判断：返回 false 时拖放区不亮起、也不接受放下（例如后缀名不对）。
    /// 闭包里可以顺手更新状态行，把拒绝的原因讲清楚。
    var willAcceptPaths: (([String]) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("DITKit 的界面全是代码搭的，不支持从 nib 加载")
    }

    override func mouseDown(with event: NSEvent) {
        if !enabled { return }
        onClick?()
    }

    private func filePaths(from pb: NSPasteboard?) -> [String] {
        DITFilePathsFromPasteboard(pb)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !enabled { return [] }
        let paths = filePaths(from: sender.draggingPasteboard)
        if paths.isEmpty { return [] }
        // 后缀名不对就直接亮「禁止」光标，别等放下之后才报错
        if let willAcceptPaths, !willAcceptPaths(paths) { return [] }
        highlight = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlight = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if !enabled { return false }
        let paths = filePaths(from: sender.draggingPasteboard)
        if paths.isEmpty { return false }
        if let willAcceptPaths, !willAcceptPaths(paths) { return false }
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight = false
        let paths = filePaths(from: sender.draggingPasteboard)
        if paths.isEmpty || !enabled { return false }
        onPaths?(paths)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.0, dy: 1.0)
        let p = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)

        if highlight {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        } else {
            NSColor.controlBackgroundColor.setFill()
        }
        p.fill()

        let stroke = highlight ? NSColor.controlAccentColor : NSColor.separatorColor
        stroke.setStroke()
        p.lineWidth = 1.0
        p.setLineDash([5.0, 4.0], count: 2, phase: 0)
        p.stroke()
        p.setLineDash(nil, count: 0, phase: 0)

        let captionAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13.0),
            .foregroundColor: highlight ? NSColor.controlAccentColor : NSColor.labelColor,
        ]
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.0),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        DITDrawHintText(self, caption, hint, captionAttrs, hintAttrs)
    }
}

// MARK: - 容器

// LayoutView 只负责「翻转坐标 + 布局回调」，不画背景。
//
// 坑：早先在这里 fill 整个 bounds 画窗口底色，结果父视图的全量重绘会把
// 还没来得及重绘的子控件整片擦掉（顶栏的标题与页切换器就这么消失的）。
// 窗口底色本来就由 NSWindow.backgroundColor 负责，不需要内容视图再画一遍。
final class LayoutView: NSView {

    var onLayout: (() -> Void)?

    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        onLayout?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onLayout?()
    }
}

// MARK: - 控件工厂

/// 普通文本标签（bold=true 用主标题样式）
func DITLabel(_ text: String, _ size: CGFloat, _ bold: Bool) -> NSTextField {
    let f = NSTextField(frame: .zero)
    f.stringValue = text
    f.isEditable = false
    f.isSelectable = false
    f.isBezeled = false
    f.drawsBackground = false
    f.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    f.textColor = bold ? NSColor.labelColor : NSColor.secondaryLabelColor
    f.autoresizingMask = []
    return f
}

/// 分区标题，如「1 · LUT 文件」
func DITSectionLabel(_ text: String) -> NSTextField {
    DITLabel(text, 12, true)
}

/// 次要操作的圆角小按钮（「添加文件…」「删除选中」这类）
func DITButton(_ title: String, _ target: AnyObject?, _ action: Selector?) -> NSButton {
    let b = NSButton(frame: .zero)
    b.title = title
    b.bezelStyle = .rounded
    b.font = NSFont.systemFont(ofSize: 12)
    b.target = target
    b.action = action
    return b
}

/// 统一取整摆放，避免亚像素造成的模糊
func DITFrame(_ v: NSView?, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
    guard let v else { return }
    v.frame = NSRect(x: round(x), y: round(y), width: round(max(1, w)), height: round(max(1, h)))
}

/// 摆放分区标题并把 y 推进到内容起点
func DITPlaceSection(_ label: NSTextField?, _ y: inout CGFloat, _ x: CGFloat, _ w: CGFloat) {
    if let label { DITFrame(label, x, y, w, 16) }
    y += 16 + 6
}

// MARK: - 任务表格

/// 列表的内容视图。列表底色本来就由它画，所以空列表的引导文字也画在这里；
/// 它还盖住整个列表可视区（行数不足时下方的空白也在其中），
/// 因此把拖放接在这里，比接在行数会变化的表格上更完整。
final class DITJobClipView: NSClipView {

    var hint: String? { didSet { needsDisplay = true } }
    var subHint: String? { didSet { needsDisplay = true } }
    var dropEnabled = true
    var onDropPaths: (([String]) -> Void)?

    private var highlight = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("DITKit 的界面全是代码搭的，不支持从 nib 加载")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if highlight {
            let r = bounds.insetBy(dx: 1.5, dy: 1.5)
            let p = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            p.lineWidth = 2.0
            NSColor.controlAccentColor.setStroke()
            p.stroke()
        }

        guard let hint, !hint.isEmpty else { return }
        let captionAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13.0),
            .foregroundColor: NSColor.labelColor,
        ]
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.0),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        DITDrawHintText(self, hint, subHint, captionAttrs, hintAttrs)
    }

    // MARK: 拖放

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !dropEnabled { return [] }
        if DITFilePathsFromPasteboard(sender.draggingPasteboard).isEmpty { return [] }
        highlight = true
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlight = false
        needsDisplay = true
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if !dropEnabled { return false }
        return !DITFilePathsFromPasteboard(sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight = false
        needsDisplay = true
        if !dropEnabled { return false }
        let paths = DITFilePathsFromPasteboard(sender.draggingPasteboard)
        if paths.isEmpty { return false }
        onDropPaths?(paths)
        return true
    }
}

/// 表格本身只多一件事：把 Delete / Backspace 交给工具页的「删除选中」。
final class DITJobTableView: NSTableView {

    var onDeleteKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        let c = chars.unicodeScalars.first?.value ?? 0
        // NSDeleteCharacter / NSBackspaceCharacter / NSDeleteFunctionKey
        if c == 0x7F || c == 0x08 || c == 0xF728 {
            if let onDeleteKey {
                onDeleteKey()
                return
            }
        }
        super.keyDown(with: event)
    }
}

/// 斑马纹只给自己的那一行画。
/// 不用 `NSTableView.usesAlternatingRowBackgroundColors`，是因为它铺的是整张表的
/// 可视区 —— 空列表（或只有两三行）时，下面那片空白会被排满看不见的「行」，
/// 一眼看过去像是塞了一堆空条目，引导文字也被压在条纹边界上。
final class DITJobRowView: NSTableRowView {

    /// 这一行要不要铺斑马纹。由 delegate 在行视图刚加进来时告知 —— NSTableRowView
    /// 没有暴露 row，自己算不出奇偶。
    var striped = false

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if !striped { return }
        // 这个数组的第 0 个就是普通行底色，第 1 个才是条纹色
        let cols = NSColor.alternatingContentBackgroundColors
        if cols.count < 2 { return }
        cols[1].setFill()
        dirtyRect.fill(using: .sourceOver)
    }
}

/// 三列任务表（文件 / 位置 / 状态），各工具页共用。
///
/// 列表本身就是拖入区：整块内容视图（含行下方的空白）都能接住文件，
/// 空列表时在中间显示引导文字。列分隔条可以拖，拖过之后就不再自动分配列宽。
final class DITJobTable: NSObject {

    let scrollView: NSScrollView
    var jobs: [DITJob] = []

    /// 空列表时显示在中间的引导（主句 + 可选副句）
    var emptyHint: String? { didSet { syncEmptyHint() } }
    var emptySubHint: String? { didSet { syncEmptyHint() } }

    /// 拖入文件/文件夹时回调；paths 没做过滤，由工具页决定怎么处理
    var onDropPaths: (([String]) -> Void)?
    /// 处理中要关掉拖入
    var dropEnabled = true { didSet { clip.dropEnabled = dropEnabled } }
    /// 选中项变化（用来刷新「删除选中」按钮的可用状态）
    var onSelectionChanged: (() -> Void)?
    /// 在列表里按了 Delete / Backspace（等价于点「删除选中」）
    var onDeleteRequested: (() -> Void)?

    private let table = DITJobTableView(frame: .zero)
    private let clip = DITJobClipView(frame: .zero)
    private var columnsUserAdjusted = false          // 用户拖过分隔条之后就不再自动分配列宽
    private var lastAssigned: [CGFloat] = []         // 上一次由我们设定的列宽，用来识别用户拖动

    override init() {
        scrollView = NSScrollView(frame: .zero)
        super.init()

        table.onDeleteKey = { [weak self] in self?.onDeleteRequested?() }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        // 斑马纹自己画（见 DITJobRowView），别让表格把空白区也铺上条纹
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        // 只允许拖列宽，不允许拖着列跑位（列的位置由布局决定）
        table.allowsColumnResizing = true
        table.allowsColumnReordering = false
        // 列宽是我们自己分配的（见 layoutColumnsForWidth），
        // 所以关掉 AppKit 的自动分配，免得它把用户拖出来的宽度又抹平
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: 22))

        for (title, width) in [("文件", 260.0), ("位置", 240.0), ("状态", 150.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
            col.title = title
            col.width = width
            // 三列都允许用户拖分隔条调整；位置列额外参与窗口缩放时的余量分配
            col.resizingMask = .userResizingMask
            table.addTableColumn(col)
        }
        table.tableColumns[1].resizingMask.insert(.autoresizingMask)

        clip.onDropPaths = { [weak self] paths in self?.onDropPaths?(paths) }

        scrollView.contentView = clip      // 要在设 documentView 之前换掉内容视图
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        // 横向滚动条只在用户把列拖宽之后才需要（见 layoutColumnsForWidth），
        // 平时列宽是按容器算的，不打开它就不会出现多余的滚动条
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true
    }

    // MARK: 空状态

    /// 只有空列表时才显示引导文字，有内容就把它收掉
    private func syncEmptyHint() {
        let empty = jobs.isEmpty
        clip.hint = empty ? emptyHint : nil
        clip.subHint = empty ? emptySubHint : nil
    }

    // MARK: 选中与删除

    var hasSelection: Bool { !table.selectedRowIndexes.isEmpty }

    var selectedJobs: [DITJob] {
        table.selectedRowIndexes.compactMap { $0 < jobs.count ? jobs[$0] : nil }
    }

    /// 全选（自检与「删除选中」配合用）
    func selectAllJobs() {
        table.selectAll(nil)
    }

    /// 删除选中项，返回实际删掉的条数
    @discardableResult
    func removeSelectedJobs() -> Int {
        let sel = table.selectedRowIndexes
        if sel.isEmpty { return 0 }
        let n = sel.count
        jobs = jobs.enumerated().filter { !sel.contains($0.offset) }.map(\.element)
        table.deselectAll(nil)
        table.reloadData()
        syncEmptyHint()
        onSelectionChanged?()
        return n
    }

    func reloadAll() {
        table.reloadData()
        syncEmptyHint()
    }

    func reloadRowOfJob(_ job: DITJob) {
        guard let row = jobs.firstIndex(where: { $0 === job }) else { return }
        table.reloadData(forRowIndexes: IndexSet(integer: row),
                         columnIndexes: IndexSet(integersIn: 0..<3))
    }

    /// 按容器宽度重新分配三列宽度（文件列与状态列按比例，位置列吃掉余量）。
    /// 一旦发现列宽不是我们上次设的值，就认定用户拖过分隔条，从此不再插手。
    func layoutColumnsForWidth(_ w: CGFloat) {
        let cols = table.tableColumns
        if cols.count != 3 { return }

        if !columnsUserAdjusted && lastAssigned.count == 3 {
            for i in 0..<3 {
                if abs(cols[i].width - lastAssigned[i]) > 1.0 {
                    columnsUserAdjusted = true
                    break
                }
            }
        }
        if columnsUserAdjusted {
            // 用户调过的列宽加起来可能超过可视宽度，这时才需要横向滚动条
            scrollView.hasHorizontalScroller = true
            return
        }

        // 减去列间距，避免总宽比可视宽度多出几个像素、白冒一条横向滚动条
        let tw = w - 8
        cols[0].width = max(150.0, tw * 0.34)
        cols[2].width = max(120.0, tw * 0.22)
        cols[1].width = max(120.0, tw - cols[0].width - cols[2].width - 3)
        lastAssigned = [cols[0].width, cols[1].width, cols[2].width]
    }

    // MARK: 自检与诊断

    /// 自检用：直接把第 index 列加宽 delta，等价于用户拖了一下分隔条
    func simulateColumnResize(_ index: Int, delta: CGFloat) {
        let cols = table.tableColumns
        if index < 0 || index >= cols.count { return }
        let c = cols[index]
        c.width = max(40.0, c.width + delta)
    }

    /// 自检/诊断用：当前各列列宽
    var columnWidths: [CGFloat] { table.tableColumns.map(\.width) }

    /// 自检/诊断用：当前各列的 resizingMask（含 userResizingMask 才拖得动）
    var columnResizingMasks: [UInt] { table.tableColumns.map(\.resizingMask.rawValue) }
}

// MARK: - 数据源

extension DITJobTable: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        jobs.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row >= 0, row < jobs.count else { return nil }
        let job = jobs[row]
        let ident = tableColumn.identifier

        var cell = tableView.makeView(withIdentifier: ident, owner: self) as? NSTableCellView
        if cell == nil {
            let c = NSTableCellView(frame: NSRect(x: 0, y: 0, width: tableColumn.width, height: 22))
            c.identifier = ident
            let tf = NSTextField(frame: NSRect(x: 2, y: 1, width: tableColumn.width - 4, height: 20))
            tf.isBordered = false
            tf.drawsBackground = false
            tf.isEditable = false
            tf.isSelectable = false
            tf.lineBreakMode = .byTruncatingMiddle
            tf.autoresizingMask = [.width, .height]
            tf.font = NSFont.systemFont(ofSize: 12)
            c.addSubview(tf)
            c.textField = tf
            cell = c
        }
        guard let cell, let tf = cell.textField else { return nil }

        var text = ""
        var color = NSColor.labelColor
        switch ident.rawValue {
        case "文件":
            text = job.displayName
        case "位置":
            text = job.displayFolder
            color = NSColor.secondaryLabelColor
        default:
            text = job.statusText
            switch job.state {
            case .done:      color = NSColor.systemGreen
            case .failed:    color = NSColor.systemRed
            case .skipped:   color = NSColor.systemOrange
            case .running:   color = NSColor.controlAccentColor
            case .cancelled: color = NSColor.secondaryLabelColor
            case .pending:   color = NSColor.tertiaryLabelColor
            }
        }
        tf.stringValue = text
        tf.textColor = color
        cell.toolTip = job.errorText.isEmpty ? job.inputPath : job.errorText
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChanged?()
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        DITJobRowView(frame: .zero)
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? DITJobRowView)?.striped = (row % 2 == 1)
    }
}

// MARK: - 底部操作栏

/// 开始 / 停止 / 清空 / 打开输出目录 + 进度条 + 状态行
final class DITActionBar: NSObject {

    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onClear: (() -> Void)?
    var onReveal: (() -> Void)?

    /// 状态行当前文字（自检断言用）
    var statusText: String { statusLabel.stringValue }

    private let progress = NSProgressIndicator(frame: .zero)
    private let statusLabel = DITLabel("就绪", 12, false)
    private let startBtn = NSButton(frame: .zero)
    private let stopBtn = NSButton(frame: .zero)
    private let clearBtn = NSButton(frame: .zero)
    private let revealBtn = NSButton(frame: .zero)

    override init() {
        super.init()

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = 0

        startBtn.title = "开始转换"
        startBtn.bezelStyle = .rounded
        startBtn.keyEquivalent = "\r"
        startBtn.target = self
        startBtn.action = #selector(startClicked)

        stopBtn.title = "停止"
        stopBtn.bezelStyle = .rounded
        stopBtn.target = self
        stopBtn.action = #selector(stopClicked)

        clearBtn.title = "清空列表"
        clearBtn.bezelStyle = .rounded
        clearBtn.target = self
        clearBtn.action = #selector(clearClicked)

        revealBtn.title = "打开输出目录"
        revealBtn.bezelStyle = .rounded
        revealBtn.target = self
        revealBtn.action = #selector(revealClicked)
    }

    func addToView(_ superview: NSView) {
        for v in [progress, statusLabel, startBtn, stopBtn, clearBtn, revealBtn] {
            superview.addSubview(v)
        }
    }

    @objc private func startClicked() { onStart?() }
    @objc private func stopClicked() { onStop?() }
    @objc private func clearClicked() { onClear?() }
    @objc private func revealClicked() { onReveal?() }

    func setStartTitle(_ title: String) {
        startBtn.title = title
    }

    func setStatus(_ status: String) {
        statusLabel.stringValue = status
    }

    func setProgress(_ progress: Double) {
        self.progress.doubleValue = progress
    }

    func setRunning(_ running: Bool, canStart: Bool) {
        startBtn.isEnabled = (!running && canStart)
        stopBtn.isEnabled = running
        clearBtn.isEnabled = !running
    }

    /// 单独控制「停止」键。停止过程中把它置灰，避免重复点击
    func setStopEnabled(_ enabled: Bool) {
        stopBtn.isEnabled = enabled
    }

    /// 从容器底部向上排放，返回表格区可用的底部边界
    func layoutFromBottom(_ bottom: CGFloat, x: CGFloat, width w: CGFloat) -> CGFloat {
        DITFrame(startBtn, x, bottom - 30, 110, 30)
        DITFrame(stopBtn, x + 118, bottom - 30, 80, 30)
        DITFrame(clearBtn, x + 206, bottom - 30, 100, 30)
        DITFrame(revealBtn, x + 314, bottom - 30, 120, 30)
        DITFrame(progress, x, bottom - 30 - 10 - 14, w, 14)
        DITFrame(statusLabel, x, bottom - 30 - 10 - 14 - 22, w, 18)
        return bottom - 30 - 10 - 14 - 22 - 8
    }
}

// MARK: - 工具页协议

/// 一个工具页（LUT 批量调色、视频裁剪 …）。主窗口只管切换，不关心页里有什么。
@objc protocol DITToolPage: NSObjectProtocol {
    /// 页面根容器
    var view: NSView { get }
    /// 切换控件上显示的名字
    var pageTitle: String { get }
    /// 是否正在处理任务（切换页、关窗时用得上）
    var busy: Bool { get }
    /// 容器尺寸确定后重排内部控件
    func layoutInBounds(_ bounds: NSRect)

    /// 外部投喂文件（打开文件、自检注入）
    @objc optional func addInputPaths(_ paths: [String])
    /// 直接开始处理（等价于点「开始」按钮；自检、将来的「拖入即跑」都用它）
    @objc optional func beginRun()
    /// 直接停止（等价于点「停止」按钮；主要给自检用）
    @objc optional func beginStop()
    /// 全选列表里的条目（自检用）
    @objc optional func selectAllJobs()
    /// 删除列表里选中的条目（等价于点「删除选中」按钮；自检用）
    @objc optional func deleteSelectedJobs()
    /// 自检用：模拟拖动列表的列分隔条（把第 index 列加宽 delta）
    @objc optional func simulateColumnResize(_ index: Int, delta: CGFloat)
    /// 状态行当前文字（自检断言用）
    @objc optional func statusLine() -> String
}
