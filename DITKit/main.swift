//
//  main.swift —— DITKit 入口与主窗口
//
//  DITKit 是个视频工具箱：主窗口只负责标题栏、ffmpeg 状态和工具页切换，
//  每个具体功能都是一个独立的 DITToolPage（见 PageLUT.swift / PageTrim.swift /
//  PageAudio.swift）。要加新工具，写一个新的 Page 类、在这里的 pages 数组里挂上即可。
//

import AppKit
import Darwin   // dlopen / dlsym：动态解析运行时的私有符号

/// --selftest：跑完自检就打印诊断信息退出。也用来在无窗口环境里驱动界面行为。
var gSelfTest = false

// MARK: - 环境变量小工具

/// 读环境变量里的整数；解析前缀数字，非法值当 0
private func DITEnvInt(_ name: String, _ fallback: Int) -> Int {
    guard let s = ProcessInfo.processInfo.environment[name] else { return fallback }
    return (s as NSString).integerValue
}

/// 读环境变量里的浮点数；解析前缀数字，非法值当 0
private func DITEnvDouble(_ name: String, _ fallback: Double) -> Double {
    guard let s = ProcessInfo.processInfo.environment[name] else { return fallback }
    return (s as NSString).doubleValue
}

/// 按 UTF-8 字节数左对齐补空格到 n 字节。
/// 用字节而不是字符：诊断行里混着中文页名，按字节算才能让各列对齐。
private func DITPad(_ s: String, _ n: Int) -> String {
    let b = s.utf8.count
    return b >= n ? s : s + String(repeating: " ", count: n - b)
}

/// 视图的类名。Swift 的 NSStringFromClass 会给普通 Swift 类加上模块名前缀
/// （`DITKit.DITJobClipView`），诊断行里要的是干净的短名。
private func DITClassName(_ v: Any) -> String {
    String(describing: type(of: v))
}

// MARK: - 窗口抓图（绕开 macOS 15 的编译期弃用）

// CGWindowListCreateImage 在 macOS 15 的 SDK 里被标记为 obsoleted，
// 直接调用会编译失败；但符号在运行时的 CoreGraphics 里仍然存在。
// 这里用 dlsym 动态解析，编译期不需要声明，运行时能用就用。
private typealias DITCGWindowListCreateImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

private let ditWindowImageFn: DITCGWindowListCreateImageFn? = {
    guard let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else {
        return nil
    }
    guard let sym = dlsym(h, "CGWindowListCreateImage") else { return nil }
    return unsafeBitCast(sym, to: DITCGWindowListCreateImageFn.self)
}()

/// 抓取指定窗口的位图；不可用时返回 nil（调用方自行回退）
private func DITCaptureWindow(_ win: NSWindow) -> NSBitmapImageRep? {
    guard let fn = ditWindowImageFn, win.windowNumber > 0 else { return nil }
    // 这个符号遵循 CF 的 Create 规则，拿到的是 +1 引用，交给 takeRetainedValue 管
    guard let img = fn(CGRect.null,
                       CGWindowListOption.optionIncludingWindow.rawValue,
                       CGWindowID(win.windowNumber),
                       CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue() else {
        return nil
    }
    return NSBitmapImageRep(cgImage: img)
}

// MARK: - 主控制器

final class AppController: NSObject, NSApplicationDelegate {

    private var window: NSWindow!
    private var root: LayoutView!
    private var titleLabel: NSTextField!
    private var ffmpegLabel: NSTextField!
    private var pageSwitch: NSSegmentedControl!
    private var pageHost: NSView!
    private var topBar: NSView!
    private var pages: [DITToolPage] = []
    private var currentPage = 0

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        buildWindow()
        doLayout()

        if let ff = DITEngine.resolveTool("ffmpeg") {
            ffmpegLabel.stringValue = "ffmpeg: \(ff)"
            ffmpegLabel.textColor = NSColor.tertiaryLabelColor
        } else {
            ffmpegLabel.stringValue = "未找到 ffmpeg —— 请先执行 brew install ffmpeg"
            ffmpegLabel.textColor = NSColor.systemRed
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // 自检时把窗口编号打出来，方便外部（如 screencapture -l）抓这个窗口
        if gSelfTest {
            print("WINDOW=\(window.windowNumber)")
            fflush(stdout)
        }

        if gSelfTest { runSelfTest() }
    }

    /// 自检：可选切换页、注入文件、按指定外观渲染截图，然后打印诊断信息退出
    private func runSelfTest() {
        let env = ProcessInfo.processInfo.environment

        if let ap = env["DITKIT_APPEARANCE"] {
            let name: NSAppearance.Name = (ap == "light") ? .aqua : .darkAqua
            if let a = NSAppearance(named: name) {
                window.appearance = a
                root.appearance = a
            }
        }

        if env["DITKIT_PAGE"] != nil {
            let idx = DITEnvInt("DITKIT_PAGE", 0)
            if idx >= 0 && idx < pages.count { pageSwitch.selectedSegment = idx }
            switchPage(nil)
        }

        if let drop = env["DITKIT_DROP"] {
            let page = pages[currentPage]
            page.addInputPaths?(drop.components(separatedBy: "|"))
            doLayout()
        }

        // DITKIT_LUT_DROP：模拟把文件拖进 LUT 拖放区（用来验证后缀名过滤）
        if let lutDrop = env["DITKIT_LUT_DROP"] {
            let page = pages[currentPage]
            if let lut = page as? PageLUT {
                _ = lut.simulateLUTDrop(lutDrop.components(separatedBy: "|"))
            }
        }

        // DITKIT_COLUMN_DRAG=<列号>:<加宽量>：模拟拖一次列分隔条，随后再走一遍布局 ——
        // 用户调过的列宽不该被「按容器宽度自动分配」抹掉
        if let colDrag = env["DITKIT_COLUMN_DRAG"] {
            let parts = colDrag.components(separatedBy: ":")
            let page = pages[currentPage]
            if parts.count == 2 {
                page.simulateColumnResize?((parts[0] as NSString).integerValue,
                                           delta: (parts[1] as NSString).doubleValue)
                doLayout()
            }
        }

        // DITKIT_LIST_ACTION=select-all|delete|delete-all：驱动列表的选中与删除
        if let act = env["DITKIT_LIST_ACTION"] {
            let page = pages[currentPage]
            if act == "select-all" || act == "delete-all" {
                page.selectAllJobs?()
            }
            if act.hasPrefix("delete") {
                page.deleteSelectedJobs?()
            }
            doLayout()
        }

        let autostart = env["DITKIT_AUTOSTART"] != nil
        if autostart {
            pages[currentPage].beginRun?()
        }

        // DITKIT_STOP_AFTER 秒后自动点一次「停止」，用于复现/回归停止路径
        if let stopAfter = env["DITKIT_STOP_AFTER"] {
            let after = (stopAfter as NSString).doubleValue
            Timer.scheduledTimer(withTimeInterval: after, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.pages[self.currentPage].beginStop?()
            }
        }

        var shotPath = ""
        if let shot = env["DITKIT_SHOT"] { shotPath = shot }

        // DITKIT_EXIT_WHEN_IDLE：轮询到当前页处理完就收尾退出，不死等固定秒数。
        // 测试套件用这个，避免「sleep 28 秒但实际 9 秒就跑完」这种既慢又不稳的写法。
        if env["DITKIT_EXIT_WHEN_IDLE"] != nil {
            let limit = DITEnvDouble("DITKIT_TIMEOUT", 60.0)
            let t0 = Date()
            var sawBusy = false
            Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] tm in
                guard let self else { tm.invalidate(); return }
                let page = self.pages[self.currentPage]
                let busy = page.busy
                if busy { sawBusy = true }
                let elapsed = Date().timeIntervalSince(t0)
                let timedOut = elapsed > limit
                // 自动开始的场景必须先看到「忙过」，否则会在任务真正跑起来之前就退出
                let ready = autostart ? (sawBusy && !busy) : true
                if (ready && elapsed >= 0.8) || timedOut {
                    tm.invalidate()
                    if timedOut { print(String(format: "等待超时: %.0f 秒", limit)) }
                    if !shotPath.isEmpty { self.captureSelf(shotPath) }
                    self.dumpDiagnostics()
                    NSApplication.shared.terminate(nil)
                }
            }
            return
        }

        let delay = DITEnvDouble("DITKIT_SHOT_DELAY", 1.6)
        Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            if !shotPath.isEmpty { self.captureSelf(shotPath) }
            self.dumpDiagnostics()
            // DITKIT_LINGER 秒：继续留在屏幕上，方便外部截图或肉眼确认
            let wait = DITEnvDouble("DITKIT_LINGER", 0)
            if wait > 0 {
                print(String(format: "保持窗口 %.0f 秒（窗口编号 %ld）", wait, self.window.windowNumber))
                fflush(stdout)
                Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { _ in
                    NSApplication.shared.terminate(nil)
                }
            } else {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func captureSelf(_ path: String) {
        // 优先按窗口抓图：cacheDisplayInRect 抓不到 layer-backed 的顶层控件（标题、切换条）
        // DITKIT_SHOT_VIEWCACHE=1 可强制走视图缓存路径，便于对比两种抓图的效果
        var rep: NSBitmapImageRep?
        if ProcessInfo.processInfo.environment["DITKIT_SHOT_VIEWCACHE"] == nil {
            rep = DITCaptureWindow(window)
        }
        if let r = rep {
            print("抓图方式: 窗口合成 (\(r.pixelsWide)x\(r.pixelsHigh))")
        } else {
            print("抓图方式: 视图缓存回退（窗口合成不可用）")
            let bounds = root.bounds
            if let r = root.bitmapImageRepForCachingDisplay(in: bounds) {
                root.cacheDisplay(in: bounds, to: r)
                rep = r
            }
        }
        guard let rep else {
            print("抓图失败: 两种方式都没拿到位图")
            return
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        if (try? png.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil {
            print("界面渲染图: \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
        }
    }

    private func dumpDiagnostics() {
        print("=== 自检 ===")
        let sc = window.screen ?? NSScreen.main
        let sf = sc?.frame ?? .zero
        let sv = sc?.visibleFrame ?? .zero
        print(String(format: "屏幕    : %.0fx%.0f  可见 y=%.0f h=%.0f",
                     sf.size.width, sf.size.height, sv.origin.y, sv.size.height))
        print(String(format: "窗口矩形: x=%.0f y=%.0f w=%.0f h=%.0f",
                     window.frame.origin.x, window.frame.origin.y,
                     window.frame.size.width, window.frame.size.height))
        print(String(format: "窗口    : %.0f x %.0f  可见=%d  编号=%ld",
                     window.frame.size.width, window.frame.size.height,
                     window.isVisible ? 1 : 0, window.windowNumber))
        print(String(format: "内容区  : %.0f x %.0f（flipped=%d）",
                     root.bounds.size.width, root.bounds.size.height, root.isFlipped ? 1 : 0))
        print("ffmpeg  : \(ffmpegLabel.stringValue)")
        print("工具页  : \(pages.count) 个")
        for (i, p) in pages.enumerated() {
            print("  [\(i)] " + DITPad(p.pageTitle, 16) + " " + (i == currentPage ? "<- 当前" : ""))
        }

        // 当前页的运行态：自检用它断言「停止后是否真的收尾了」
        let cur = pages[currentPage]
        print("运行态  : busy=\(cur.busy ? 1 : 0)  状态行=\(cur.statusLine?() ?? "(未实现)")")

        print("顶层子视图:")
        for v in root.subviews {
            let geo = String(format: " x=%4.0f y=%4.0f w=%4.0f h=%4.0f hidden=%d",
                             v.frame.origin.x, v.frame.origin.y,
                             v.frame.size.width, v.frame.size.height, v.isHidden ? 1 : 0)
            print("  " + DITPad(DITClassName(v), 20) + geo)
        }

        print("顶栏控件状态:")
        print("  _root 是窗口内容视图: \(window.contentView === root ? 1 : 0)")
        let barViews: [NSView] = [titleLabel, ffmpegLabel, pageSwitch, topBar]
        for v in barViews {
            let vis = v.visibleRect
            let head = "  " + DITPad(DITClassName(v), 20)
            let mid = String(format: " alpha=%.2f 隐藏祖先=%d layer=%d",
                             v.alphaValue,
                             v.isHiddenOrHasHiddenAncestor ? 1 : 0,
                             v.wantsLayer ? 1 : 0)
            let tail = String(format: " 可见区=[%.0f,%.0f,%.0f,%.0f]",
                              vis.origin.x, vis.origin.y, vis.size.width, vis.size.height)
            print(head + mid + " 外表=" + v.effectiveAppearance.name.rawValue + tail)
        }

        let pageView = pages[currentPage].view
        print("当前页视图: \(DITClassName(pageView))  "
              + String(format: "%.0f x %.0f", pageView.frame.size.width, pageView.frame.size.height)
              + "  子视图 \(pageView.subviews.count) 个")

        // 按 y 升序（翻转坐标系里就是从上到下）。Swift 的 sorted 不保证稳定，
        // 所以把原始次序当作并列时的次级键，让同 y 的控件顺序始终可预期。
        let sorted = pageView.subviews.enumerated()
            .sorted { a, b in
                let ya = a.element.frame.origin.y, yb = b.element.frame.origin.y
                return ya != yb ? ya < yb : a.offset < b.offset
            }
            .map(\.element)

        for v in sorted {
            var extra = ""
            if let tf = v as? NSTextField {
                var s = tf.stringValue
                if s.count > 26 { s = String(s.prefix(26)) + "…" }
                extra = "  \"\(s)\""
            } else if let well = v as? DropWellView {
                extra = "  [\(well.caption)]"
            } else if let sv = v as? NSScrollView {
                // 任务列表：列宽与「能不能拖」都从掩码上看，行数用来断言增删
                if let tv = sv.documentView as? NSTableView {
                    let ws = tv.tableColumns.map { String(format: "%.0f", $0.width) }
                    let ms = tv.tableColumns.map { String($0.resizingMask.rawValue) }
                    extra = "  rows=\(tv.numberOfRows) w=[\(ws.joined(separator: ","))]"
                        + " mask=[\(ms.joined(separator: ","))]"
                }
            } else if let tv = v as? NSTableView {
                extra = "  cols=\(tv.numberOfColumns)"
                    + String(format: " rowH=%.0f", tv.rowHeight)
            } else if let btn = v as? NSButton {
                extra = "  \"\(btn.title)\" state=\(btn.state.rawValue) enabled=\(btn.isEnabled ? 1 : 0)"
            }
            let geo = String(format: " x=%4.0f y=%4.0f w=%4.0f h=%3.0f",
                             v.frame.origin.x, v.frame.origin.y,
                             v.frame.size.width, v.frame.size.height)
            print("  " + DITPad(DITClassName(v), 22) + geo + extra)
        }
        print("=== 自检结束 ===")
        fflush(stdout)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildMenu() {
        let menubar = NSMenu()
        let appItem = NSMenuItem()
        menubar.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 DITKit",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApplication.shared.mainMenu = menubar
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        pages[currentPage].addInputPaths?(filenames)
        sender.reply(toOpenOrPrint: .success)
    }

    // MARK: 构建窗口

    private func buildWindow() {
        let frame = NSRect(x: 0, y: 0, width: 740, height: 850)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered,
                          defer: false)
        window.title = "DITKit"
        window.minSize = NSSize(width: 700, height: 760)
        // 窗口底色由窗口负责（内容视图不自己画背景，见 DITUI.swift 的说明）
        window.backgroundColor = NSColor.windowBackgroundColor
        window.center()

        root = LayoutView(frame: frame)
        root.onLayout = { [weak self] in self?.doLayout() }
        window.contentView = root

        // 顶栏：标题 + ffmpeg 状态 + 工具页切换
        // 单独放进一个容器视图，而不是直接挂在内容视图上（直接挂会导致控件不被绘制）
        topBar = NSView(frame: .zero)
        root.addSubview(topBar)

        titleLabel = DITLabel("DITKit", 15, true)
        topBar.addSubview(titleLabel)
        ffmpegLabel = DITLabel("", 11, false)
        ffmpegLabel.alignment = .right
        topBar.addSubview(ffmpegLabel)

        // 工具页切换
        pages = [PageLUT(), PageTrim(), PageAudio()]
        pageSwitch = NSSegmentedControl(frame: .zero)
        pageSwitch.segmentCount = pages.count
        for (i, p) in pages.enumerated() {
            pageSwitch.setLabel(p.pageTitle, forSegment: i)
        }
        pageSwitch.selectedSegment = 0
        pageSwitch.segmentStyle = .texturedRounded
        pageSwitch.target = self
        pageSwitch.action = #selector(switchPage(_:))
        topBar.addSubview(pageSwitch)

        // 页面容器：所有页都挂进来，用 hidden 控制显示，这样各自的输入状态不会丢
        pageHost = NSView(frame: .zero)
        root.addSubview(pageHost)
        for p in pages {
            p.view.isHidden = true
            pageHost.addSubview(p.view)
        }
        currentPage = 0
        pages[0].view.isHidden = false
    }

    @objc private func switchPage(_ sender: Any?) {
        let idx = pageSwitch.selectedSegment
        if idx < 0 || idx >= pages.count { return }
        for (i, p) in pages.enumerated() {
            p.view.isHidden = (i != idx)
        }
        currentPage = idx
        doLayout()
    }

    // MARK: 布局

    private func doLayout() {
        if root == nil || pageHost == nil { return }
        let b = root.bounds
        let W = b.size.width
        let H = b.size.height
        let PAD: CGFloat = 18.0
        let x = PAD
        let w = W - PAD * 2
        var y = PAD

        // 顶栏容器：普通 NSView（非翻转），子控件坐标自下而上
        let BAR_H: CGFloat = 66.0
        DITFrame(topBar, x, y, w, BAR_H)
        DITFrame(titleLabel, 0, BAR_H - 20, w * 0.5, 20)
        DITFrame(ffmpegLabel, w * 0.5, BAR_H - 18, w * 0.5, 16)
        let switchW = min(w, 130.0 * CGFloat(pages.count))
        DITFrame(pageSwitch, 0, BAR_H - 56, switchW, 26)
        y += BAR_H + 10

        DITFrame(pageHost, x, y, w, max(120, H - PAD - y))

        // 页面视图铺满容器，并让它自己重排内部控件
        let host = pageHost.bounds
        for p in pages {
            DITFrame(p.view, 0, 0, host.size.width, host.size.height)
            p.layoutInBounds(p.view.bounds)
        }
    }
}

// MARK: - 命令行

private func PrintUsage() {
    var text = "DITKit —— 视频工具箱\n\n"
    text += "  DITKit                                 打开图形界面\n"
    text += "  DITKit --cli --lut  <LUT> [选项] -- <视频...>    批量套 LUT\n"
    text += "  DITKit --cli --trim --end <时间> [选项] -- <视频...>   裁剪片段\n"
    text += "  DITKit --cli --audio [--start <时间>] [--end <时间>] [选项] -- <文件...>   提取音频\n\n"
    text += "LUT 模式:\n" + PageLUT.cliUsage + "\n"
    text += "裁剪模式:\n" + PageTrim.cliUsage + "\n"
    text += "音频提取模式:\n" + PageAudio.cliUsage
    FileHandle.standardError.write(Data(text.utf8))
}

private func RunCLI(_ args: [String]) -> Int32 {
    var wantsLUT = false, wantsTrim = false, wantsAudio = false
    for a in args {
        if a == "--lut" { wantsLUT = true }
        if a == "--trim" { wantsTrim = true }
        if a == "--audio" { wantsAudio = true }
    }
    if wantsLUT { return PageLUT.runCLI(args) }
    if wantsTrim { return PageTrim.runCLI(args) }
    if wantsAudio { return PageAudio.runCLI(args) }
    PrintUsage()
    return 2
}

// MARK: - 入口

let ditArgs = CommandLine.arguments
if ditArgs.count >= 2 && ditArgs[1] == "--cli" {
    exit(RunCLI(Array(ditArgs.dropFirst(2))))
}
if ditArgs.count >= 2 && (ditArgs[1] == "--help" || ditArgs[1] == "-h") {
    PrintUsage()
    exit(0)
}
if ditArgs.count >= 2 && ditArgs[1] == "--selftest" { gSelfTest = true }

let ditApp = NSApplication.shared
ditApp.setActivationPolicy(.regular)
let ditController = AppController()
ditApp.delegate = ditController
ditApp.run()
