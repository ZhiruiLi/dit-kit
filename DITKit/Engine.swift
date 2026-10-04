//
//  Engine.swift —— DITKit 通用转换引擎
//
//  这里只放「与具体工具无关」的东西：
//    · DITJob           任务模型
//    · DITOutputOptions 输出路径 / 命名冲突 / 并发数 / 扩展名过滤
//    · DITEngine        并发执行器：调度 ffmpeg 子进程、解析进度、汇报状态
//
//  具体工具通过 argumentsBuilder 回调提供自己的 ffmpeg 参数，
//  所以新增一个工具不需要动这个文件。
//
//  另外这里也放着与具体工具无关的 ffprobe 探测（时长 / 画面尺寸 / 音视频流概况）。
//
//  没跑完的任务（被停止、或 ffmpeg 报错退出）留下的产物一律改名成 `.partial`，
//  所以带视频扩展名的文件一定是成品。
//
//  自检输出里的每一行都被测试用例断言着，改文案就等于改契约。
//

import Foundation
import Darwin   // kill / SIGKILL：停止流程的信号升级兜底

// MARK: - 枚举

/// 输出位置：绝对目录，或相对于源文件的子目录
enum DITOutMode {
    case absolute
    case relativeToSource
}

/// 重名文件的处理策略
enum DITConflictPolicy {
    case skip
    case overwrite
    case rename
}

/// 单个任务的执行状态
enum DITJobState {
    case pending
    case running
    case done
    case skipped
    case failed
    case cancelled
}

// MARK: - 任务

/// 一条待处理的任务。纯数据，不知道 ffmpeg 怎么跑。
final class DITJob {
    var inputPath = ""
    var outputPath: String?
    var state: DITJobState = .pending
    var progress: Double = 0
    var statusText = "等待中"
    var errorText = ""
    /// 文件名
    var displayName = ""
    /// 所在目录（用于列表副标题）
    var displayFolder = ""
}

// MARK: - 输出策略

/// 输出路径 / 命名冲突 / 并发数 / 扩展名过滤
final class DITOutputOptions {
    var outMode: DITOutMode = .relativeToSource
    /// 绝对路径，或相对于源文件的子目录
    var outValue = "out"
    /// 输出文件名后缀
    var suffix = "_out"
    /// 输出容器的扩展名（不含点）。留空表示沿用源文件的扩展名；
    /// 换了容器的工具（如把视频里的声音提成音频）必须指定它。
    var outputExtension: String?
    var conflict: DITConflictPolicy = .skip
    var maxConcurrent = 4
    /// 空格分隔的小写扩展名
    var extensionFilter = "mp4 mov m4v mkv avi mxf mp4v hevc ts"

    /// 实际使用的输出扩展名
    func resolvedExtension(sourceExtension: String) -> String {
        guard let e = outputExtension, !e.isEmpty else { return sourceExtension }
        return e
    }
}

/// 把任务翻译成 ffmpeg 参数：自带 `-i <输入>`（需要第二路输入的工具可以再补一个 `-i`），
/// 但不要带输出文件名（引擎会补）
typealias DITArgsBuilder = (DITJob, String) -> [String]

// MARK: - 内部任务盒子

/// 一条正在跑的 ffmpeg 任务：进程 + 两条管道 + 解析进度要用的中间状态。
/// 只在引擎内部用，所以不对外暴露。
private final class DITTaskBox {
    let job: DITJob
    let task = Process()
    let outPipe = Pipe()
    let errPipe = Pipe()
    var errBuf = ""
    /// 这条任务开始跑的时刻（ffmpeg 一启动就会建好输出文件，用它区分
    /// 「本次写出来的半成品」与「启动前就摆在那里的别人的成品」）
    let startedAt = Date()
    /// ffmpeg 报告的源时长
    var durationSec: Double = 0
    /// 工具声明的预期输出时长
    var expectedSec: Double = 0
    var sawDuration = false
    var sawProgressLine = false

    init(job: DITJob) {
        self.job = job
    }
}

// MARK: - 执行器

final class DITEngine {

    /// 工具特有的前置检查；返回非空字符串则中止启动，并把它当作错误展示
    var preflight: (() -> String?)?
    /// 预期输出时长（秒），用于换算进度；不设置时回退为 ffmpeg 报告的源时长
    var expectedDuration: ((DITJob) -> Double)?
    var onJobUpdate: ((DITJob) -> Void)?
    var onFinished: (() -> Void)?

    private(set) var isRunning = false

    private let output: DITOutputOptions
    private let builder: DITArgsBuilder
    private var queue: [DITJob]
    private var active: [DITTaskBox] = []
    private var ffmpeg = ""
    private var cancelled = false

    init(jobs: [DITJob], output: DITOutputOptions, argumentsBuilder builder: @escaping DITArgsBuilder) {
        self.output = output
        self.builder = builder
        self.queue = jobs
    }

    // MARK: 启动与停止

    /// 开始执行。返回 nil 表示已经跑起来了，否则返回不能开始的原因。
    func start() -> String? {
        let fm = FileManager.default

        // 工具特有的前置检查（LUT 是否存在、时间范围是否合法 …）
        if let msg = preflight?(), !msg.isEmpty { return msg }
        if queue.isEmpty { return "还没有拖入任何视频文件" }

        guard let tool = DITEngine.resolveTool("ffmpeg") else {
            return "找不到 ffmpeg，请先执行：brew install ffmpeg"
        }
        ffmpeg = tool

        if output.outMode == .absolute {
            let dir = (output.outValue as NSString).expandingTildeInPath
            if dir.isEmpty { return "指定绝对路径模式下，输出目录不能为空" }
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            } catch {
                return "无法创建输出目录：\(error.localizedDescription)"
            }
        }

        cancelled = false
        isRunning = true
        pump()
        return nil
    }

    func cancel() {
        if !isRunning { return }
        cancelled = true

        // 1) 正在跑的：发 SIGTERM（ffmpeg 实测 0.25s 内就退出）
        let snapshot = active
        for box in snapshot where box.task.isRunning {
            box.task.terminate()
        }

        // 2) 还在排队的：直接判为已取消并把队列清空。
        //    这一步不能省 —— pump 的调度循环带 `!cancelled` 守卫，
        //    而收尾条件是 `active.isEmpty && queue.isEmpty`。
        //    只打标记不清队列的话，队列永远不会被消费，收尾条件永不成立，
        //    onFinished 不触发，界面就永久停在「正在停止…」。
        if !queue.isEmpty {
            for job in queue {
                job.state = .cancelled
                job.statusText = "已取消"
                notify(job)
            }
            queue.removeAll()
        }

        // 3) 兜底：SIGTERM 之后若还有任务赖着不走，1.5 秒后升级成 SIGKILL。
        //    硬编（Videotoolbox）偶尔会卡在驱动里不响应信号，没有这层「停止」会假死。
        if !snapshot.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                for box in self.active where box.task.isRunning {
                    kill(box.task.processIdentifier, SIGKILL)
                }
            }
        }

        // 4) 此刻若已无活跃任务，pump 会立刻收尾；否则等最后一个终止回调再收尾
        pump()
    }

    // MARK: 调度

    private func notify(_ job: DITJob) {
        onJobUpdate?(job)
    }

    private func pump() {
        let maxC = max(1, output.maxConcurrent)

        if cancelled {
            // 双保险：正常路径下 cancel 已经清空队列，这里再兜一次，
            // 保证「取消后队列必为空」这个不变量在任何调用路径下都成立。
            while !queue.isEmpty {
                let job = queue.removeFirst()
                job.state = .cancelled
                job.statusText = "已取消"
                notify(job)
            }
        } else {
            while active.count < maxC && !queue.isEmpty {
                launch(queue.removeFirst())
            }
        }

        // 收尾条件：既没有在跑的，也没有排队的
        if active.isEmpty && queue.isEmpty && isRunning {
            isRunning = false
            onFinished?()
        }
    }

    private func launch(_ job: DITJob) {
        let fm = FileManager.default
        let inPath = job.inputPath
        let srcDir = (inPath as NSString).deletingLastPathComponent

        // 输出目录
        let dir: String
        if output.outMode == .absolute {
            dir = (output.outValue as NSString).expandingTildeInPath
        } else {
            let rel = output.outValue
            if rel.isEmpty || rel == "." || rel == "./" {
                dir = srcDir
            } else {
                dir = (srcDir as NSString).appendingPathComponent(rel)
            }
        }

        let stem = ((inPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let ext = output.resolvedExtension(sourceExtension: (inPath as NSString).pathExtension)
        var name = "\(stem)\(output.suffix).\(ext)"
        var outPath = (dir as NSString).appendingPathComponent(name)

        // 命名冲突
        if output.conflict == .rename {
            var n = 1
            while fm.fileExists(atPath: outPath) {
                name = "\(stem)\(output.suffix) (\(n)).\(ext)"
                n += 1
                outPath = (dir as NSString).appendingPathComponent(name)
            }
        } else if output.conflict == .skip && fm.fileExists(atPath: outPath) {
            job.outputPath = outPath
            job.state = .skipped
            job.progress = 1.0
            job.statusText = "已存在，跳过"
            notify(job)
            return
        }

        // 防止覆盖源文件
        if (outPath as NSString).standardizingPath == (inPath as NSString).standardizingPath {
            job.state = .failed
            job.statusText = "失败"
            job.errorText = "输出路径与源文件相同：后缀不能为空，或请更换输出目录"
            notify(job)
            return
        }

        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            job.state = .failed
            job.statusText = "失败"
            job.errorText = "无法创建目录 \(dir)：\(error.localizedDescription)"
            notify(job)
            return
        }

        // 通用前缀 + 由工具页提供的参数（含 -i）+ 输出文件
        var args = ["-hide_banner", "-nostdin", "-nostats", "-progress", "pipe:1"]
        args.append(output.conflict == .overwrite ? "-y" : "-n")
        args.append(contentsOf: builder(job, outPath))
        args.append(outPath)

        let box = DITTaskBox(job: job)
        box.task.executableURL = URL(fileURLWithPath: ffmpeg)
        box.task.arguments = args
        box.task.standardOutput = box.outPipe
        box.task.standardError = box.errPipe
        box.task.standardInput = FileHandle.nullDevice
        box.expectedSec = expectedDuration?(job) ?? 0

        job.outputPath = outPath
        job.state = .running
        job.statusText = "处理中 0%"
        job.progress = 0

        // 读到输出立刻切回主线程解析 —— 界面上的进度只能主线程碰
        box.outPipe.fileHandleForReading.readabilityHandler = { [weak self, weak box] fh in
            let d = fh.availableData
            if d.isEmpty { return }
            guard let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                guard let self, let box else { return }
                self.consumeProgress(s, box: box)
            }
        }

        box.errPipe.fileHandleForReading.readabilityHandler = { [weak self, weak box] fh in
            let d = fh.availableData
            if d.isEmpty { return }
            guard let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                guard let self, let box else { return }
                self.consumeStderr(s, box: box)
            }
        }

        box.task.terminationHandler = { [weak self, weak box] t in
            guard let box else { return }
            box.outPipe.fileHandleForReading.readabilityHandler = nil
            box.errPipe.fileHandleForReading.readabilityHandler = nil
            let restOut = box.outPipe.fileHandleForReading.readDataToEndOfFile()
            let restErr = box.errPipe.fileHandleForReading.readDataToEndOfFile()
            let so = String(data: restOut, encoding: .utf8) ?? ""
            let se = String(data: restErr, encoding: .utf8) ?? ""
            let status = t.terminationStatus
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !so.isEmpty { self.consumeProgress(so, box: box) }
                if !se.isEmpty { self.consumeStderr(se, box: box) }
                self.finish(box, status: status)
            }
        }

        active.append(box)
        notify(job)

        do {
            try box.task.run()
        } catch {
            box.outPipe.fileHandleForReading.readabilityHandler = nil
            box.errPipe.fileHandleForReading.readabilityHandler = nil
            active.removeAll { $0 === box }
            job.state = .failed
            job.statusText = "失败"
            job.errorText = "无法启动 ffmpeg：\(error.localizedDescription)"
            notify(job)
        }
    }

    // MARK: 输出解析

    private func consumeProgress(_ text: String, box: DITTaskBox) {
        for rawLine in text.components(separatedBy: "\n") {
            // 注意只去掉空格和制表符：ffmpeg 的进度行本来就不带换行
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("out_time_us=") {
                // 用 NSString 的 doubleValue 而不是 Double(_:)：它按前缀解析，
                // 遇到非数字尾巴也返回 0，不会判成 nil
                let us = (String(line.dropFirst(12)) as NSString).doubleValue
                box.sawProgressLine = true
                applyTime(us / 1e6, box: box)
            } else if line.hasPrefix("out_time=") {
                let t = String(line.dropFirst(9))
                box.sawProgressLine = true
                let sec = DITEngine.secondsFromTimeString(t)
                if sec >= 0 { applyTime(sec, box: box) }
            } else if line.hasPrefix("progress=end") {
                box.job.progress = 1.0
            }
        }
    }

    private func consumeStderr(_ text: String, box: DITTaskBox) {
        box.errBuf += text
        // 只留最后 8000 个字符，失败时够贴出尾巴就行
        let buf = box.errBuf as NSString
        if buf.length > 8000 {
            box.errBuf = buf.substring(from: buf.length - 8000)
        }
        if !box.sawDuration {
            let ns = box.errBuf as NSString
            let r = ns.range(of: "Duration: ")
            if r.location != NSNotFound {
                let rest = ns.substring(from: NSMaxRange(r))
                let end = (rest as NSString).rangeOfCharacter(from: CharacterSet(charactersIn: ",\n"))
                let t = (end.location == NSNotFound) ? rest : (rest as NSString).substring(to: end.location)
                let d = DITEngine.secondsFromTimeString(t)
                if d > 0 {
                    box.durationSec = d
                    box.sawDuration = true
                }
            }
        }
    }

    private func applyTime(_ sec: Double, box: DITTaskBox) {
        let job = box.job
        let total = box.expectedSec > 0.01 ? box.expectedSec : box.durationSec
        if total > 0.01 {
            job.progress = min(1.0, max(0.0, sec / total))
        } else {
            job.progress = min(0.98, job.progress + 0.002)
        }
        job.statusText = String(format: "处理中 %.0f%%", job.progress * 100)
        notify(job)
    }

    // MARK: 收尾

    private func finish(_ box: DITTaskBox, status: Int32) {
        let job = box.job
        active.removeAll { $0 === box }

        if cancelled {
            job.state = .cancelled
            job.statusText = "已取消"
        } else if status == 0 {
            job.state = .done
            job.progress = 1.0
            job.statusText = "完成"
        } else {
            job.state = .failed
            job.statusText = "失败 (ffmpeg 退出码 \(status))"
            job.errorText = DITEngine.tail(of: box.errBuf, lines: 12)
        }

        // 没跑完的任务会在输出目录留下半个文件。ffmpeg 收到 SIGTERM 会把容器写完，
        // 所以它其实还能播 —— 顶着 .mp4 放在那里就会被当成成品。
        if job.state != .done {
            demoteToPartial(job, startedAt: box.startedAt)
        }

        notify(job)
        pump()
    }

    /// 把没跑完的产物改名成 `.partial`。
    ///
    /// 扩展名不是视频格式，一眼就能看出它不是成品；顺带把同名的成品位置空出来，
    /// 下次同一批再跑时不会被「已存在」判掉。上一次留下的同名残片没有保留价值，直接覆盖。
    private func demoteToPartial(_ job: DITJob, startedAt: Date) {
        guard let out = job.outputPath, !out.isEmpty else { return }
        guard DITEngine.isWrittenByThisRun(out, since: startedAt) else { return }

        let fm = FileManager.default
        let dir = (out as NSString).deletingLastPathComponent
        let base = ((out as NSString).lastPathComponent as NSString).deletingPathExtension
        let partial = (dir as NSString).appendingPathComponent(base + ".partial")
        do {
            if fm.fileExists(atPath: partial) { try fm.removeItem(atPath: partial) }
            try fm.moveItem(atPath: out, toPath: partial)
        } catch {
            job.errorText = "没能把没跑完的产物改名成 .partial：\(error.localizedDescription)"
        }
    }

    /// 输出文件是不是本次运行写出来的。
    ///
    /// 判断依据是修改时间：ffmpeg 打开输出文件就会建好它，所以「文件存在 + 刚被写过」
    /// 说明这是我们写了一半的产物。反过来，文件比本次启动还旧，说明 ffmpeg 根本没碰过
    /// 输出（输入探测阶段就报错、或 `-n` 撞上已有文件），那是摆在原处的成品，不能动。
    /// 容 1 秒误差：有的文件系统时间戳精度只到秒。
    static func isWrittenByThisRun(_ path: String, since: Date) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return false }
        return mtime >= since.addingTimeInterval(-1.0)
    }
}

// MARK: - 公共工具

/// 命令行模式下把当前 run loop 转到引擎自己收尾为止。
///
/// 子进程的管道回调都排在主 run loop 上，所以必须让 run loop 真的转起来，
/// 否则引擎永远等不到 terminated 回调，CLI 就卡在启动完的那一刻不动了。
func DITRunLoopUntilEngineStops(_ engine: DITEngine) {
    while engine.isRunning {
        autoreleasepool {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
    }
    // 再转一圈，确保终止回调处理完毕
    for _ in 0..<20 {
        autoreleasepool {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }
}

extension DITEngine {

    /// 在 PATH 与常见安装位置中查找可执行文件
    static func resolveTool(_ name: String) -> String? {
        let fm = FileManager.default
        var cands: [String] = []

        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in envPath.components(separatedBy: ":") where !dir.isEmpty {
            cands.append((dir as NSString).appendingPathComponent(name))
        }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            cands.append((dir as NSString).appendingPathComponent(name))
        }
        if let res = Bundle.main.resourcePath {
            cands.append((res as NSString).appendingPathComponent(name))
        }

        for p in cands where fm.isExecutableFile(atPath: p) { return p }
        return nil
    }

    /// 单行 filter 内路径转义（ffmpeg filter 语法）
    static func escapeFilterValue(_ value: String) -> String {
        var m = value
        m = m.replacingOccurrences(of: "\\", with: "\\\\")
        m = m.replacingOccurrences(of: "'", with: "\\'")
        m = m.replacingOccurrences(of: ":", with: "\\:")
        return "'\(m)'"
    }

    private static func extensionSet(fromFilter filter: String) -> Set<String> {
        var set = Set<String>()
        for p in filter.components(separatedBy: .whitespacesAndNewlines) {
            let t = p.lowercased()
            if !t.isEmpty { set.insert(t) }
        }
        if set.isEmpty {
            set.formUnion(["mp4", "mov", "m4v", "mkv", "avi", "mxf"])
        }
        return set
    }

    /// 收集视频文件（目录会递归展开）；excludeSuffix 用于跳过已处理过的产物
    static func videoFilesFromPaths(_ paths: [String], filter: String, excludeSuffix suffix: String?) -> [String] {
        let fm = FileManager.default
        let exts = extensionSet(fromFilter: filter)
        var out: [String] = []
        var seen = Set<String>()

        for p in paths {
            let abs = (p as NSString).standardizingPath
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: abs, isDirectory: &isDir) { continue }

            if isDir.boolValue {
                guard let en = fm.enumerator(atPath: abs) else { continue }
                for case let rel as String in en {
                    let full = (abs as NSString).appendingPathComponent(rel)
                    var d: ObjCBool = false
                    if !fm.fileExists(atPath: full, isDirectory: &d) || d.boolValue { continue }
                    if isSkippable(full, suffix: suffix) { continue }
                    if exts.contains((full as NSString).pathExtension.lowercased()) && !seen.contains(full) {
                        seen.insert(full)
                        out.append(full)
                    }
                }
            } else {
                if !isSkippable(abs, suffix: suffix) &&
                    exts.contains((abs as NSString).pathExtension.lowercased()) &&
                    !seen.contains(abs) {
                    seen.insert(abs)
                    out.append(abs)
                }
            }
        }
        out.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return out
    }

    /// 隐藏文件、以及文件名已经带输出后缀的产物，都不再作为输入
    private static func isSkippable(_ path: String, suffix: String?) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix(".") { return true }
        for comp in (path as NSString).pathComponents where comp.hasPrefix(".") {
            return true
        }
        // suffix 为空时 hasSuffix: 恒为真，必须先挡掉
        guard let suffix, !suffix.isEmpty else { return false }

        let stem = (name as NSString).deletingPathExtension
        if stem.hasSuffix(suffix) { return true }

        // 命名冲突选「重命名」时产物形如 <名字><后缀> (1).mp4，
        // 只认 _graded 结尾会把它们当成新素材再处理一遍，所以这里一并识别
        let ns = stem as NSString
        let r = ns.range(of: suffix + " (", options: .backwards)
        if r.location == NSNotFound { return false }
        let tail = ns.substring(from: r.location + (suffix as NSString).length) as NSString
        if tail.length < 4 || !tail.hasPrefix(" (") || !tail.hasSuffix(")") { return false }
        let digits = tail.substring(with: NSRange(location: 2, length: tail.length - 3))
        if digits.isEmpty { return false }
        return (digits as NSString).rangeOfCharacter(from: .decimalDigits.inverted).location == NSNotFound
    }

    /// 时间码 → 秒。支持 01:30:00.500 / 1:30 / 90 / 90s / 1m30s；解析失败返回 -1
    static func secondsFromTimeString(_ t: String) -> Double {
        let raw = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return -1 }

        // 时间码写法：HH:MM:SS.mmm / MM:SS.mmm
        if raw.contains(":") {
            let parts = raw.components(separatedBy: ":")
            if parts.count > 3 { return -1 }
            var total: Double = 0
            for p in parts {
                let q = p.trimmingCharacters(in: .whitespaces)
                let sc = Scanner(string: q)
                guard let v = sc.scanDouble(representation: .decimal), sc.isAtEnd else { return -1 }
                total = total * 60 + v
            }
            return total
        }

        // 带单位写法：1h30m / 90s / 1.5m / 90
        var total: Double = 0
        let sc = Scanner(string: raw.lowercased())
        while !sc.isAtEnd {
            guard let v = sc.scanDouble(representation: .decimal) else { return -1 }
            let unit = sc.scanCharacters(from: .lowercaseLetters) ?? ""
            if unit.isEmpty {
                total += v                       // 无单位按秒
            } else if unit.hasPrefix("h") {
                total += v * 3600
            } else if unit.hasPrefix("m") {
                total += v * 60
            } else if unit.hasPrefix("s") {
                total += v
            } else {
                return -1
            }
        }
        return total
    }

    /// 秒 → 00:01:30.500
    static func timeStringFromSeconds(_ s: Double) -> String {
        var v = s
        if v < 0 || !v.isFinite { v = 0 }
        var total = Int(floor(v))
        var ms = Int(((v - Double(total)) * 1000.0).rounded())
        if ms >= 1000 {
            ms -= 1000
            total += 1
        }
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return String(format: "%02d:%02d:%02d.%03d", h, m, sec, ms)
    }

    /// 跑一次 ffprobe 并取回标准输出；ffprobe 不在、或进程起不来时返回 nil
    private static func probeOutput(_ args: [String]) -> String? {
        guard let ffprobe = resolveTool("ffprobe") else { return nil }
        let t = Process()
        t.executableURL = URL(fileURLWithPath: ffprobe)
        t.arguments = args
        let p = Pipe()
        t.standardOutput = p
        t.standardError = Pipe()
        t.standardInput = FileHandle.nullDevice
        do { try t.run() } catch { return nil }
        let d = p.fileHandleForReading.readDataToEndOfFile()
        t.waitUntilExit()
        return String(data: d, encoding: .utf8)
    }

    /// ffprobe 的 `key=value` 输出解析成字典
    private static func keyValues(_ text: String) -> [String: String] {
        var kv: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            guard let eq = line.range(of: "=") else { continue }
            kv[String(line[line.startIndex..<eq.lowerBound])] = String(line[eq.upperBound...])
        }
        return kv
    }

    /// 用 ffprobe 读取媒体时长（秒），失败返回 0
    static func probeDuration(_ path: String) -> Double {
        guard let s = probeOutput(["-v", "error", "-show_entries", "format=duration",
                                   "-of", "default=nw=1:nk=1", path]) else { return 0 }
        let v = (s as NSString).doubleValue
        return (v.isFinite && v > 0) ? v : 0
    }

    /// 首个视频流的画面尺寸；没有视频流或读不出来时返回 nil
    static func probeVideoSize(_ path: String) -> (w: Int, h: Int)? {
        guard let s = probeOutput(["-v", "error", "-select_streams", "v:0",
                                   "-show_entries", "stream=width,height",
                                   "-of", "default=nw=1", path]) else { return nil }
        let kv = keyValues(s)
        let w = ((kv["width"] ?? "") as NSString).integerValue
        let h = ((kv["height"] ?? "") as NSString).integerValue
        return (w > 0 && h > 0) ? (w, h) : nil
    }

    /// 首个音频流的概况；没有音频流时返回 nil
    static func probeAudioStream(_ path: String) -> (codec: String, sampleRate: Int, channels: Int)? {
        guard let s = probeOutput(["-v", "error", "-select_streams", "a:0",
                                   "-show_entries", "stream=codec_name,sample_rate,channels",
                                   "-of", "default=nw=1", path]) else { return nil }
        if s.isEmpty { return nil }
        let kv = keyValues(s)
        let codec = kv["codec_name"] ?? ""
        if codec.isEmpty { return nil }
        return (codec,
                ((kv["sample_rate"] ?? "") as NSString).integerValue,
                ((kv["channels"] ?? "") as NSString).integerValue)
    }

    /// 音频流的一行摘要，如 `aac 48kHz 立体声`；没有音频流时返回 nil
    static func probeAudioSummary(_ path: String) -> String? {
        guard let a = probeAudioStream(path) else { return nil }
        var bits = [a.codec]
        if a.sampleRate > 0 {
            let k = Double(a.sampleRate) / 1000.0
            bits.append(a.sampleRate % 1000 == 0
                        ? "\(a.sampleRate / 1000)kHz"
                        : String(format: "%.1fkHz", k))
        }
        if a.channels > 0 { bits.append(channelName(a.channels)) }
        return bits.joined(separator: " ")
    }

    private static func channelName(_ n: Int) -> String {
        switch n {
        case 1: return "单声道"
        case 2: return "立体声"
        default: return "\(n) 声道"
        }
    }

    /// 用 ffprobe 读取一行媒体摘要（分辨率 / 帧率 / 编码），失败返回 nil
    static func probeSummary(_ path: String) -> String? {
        guard let s = probeOutput(["-v", "error", "-select_streams", "v:0",
                                   "-show_entries", "stream=codec_name,width,height,r_frame_rate",
                                   "-of", "default=nw=1", path]) else { return nil }
        if s.isEmpty { return nil }
        let kv = keyValues(s)

        var bits: [String] = []
        let w = ((kv["width"] ?? "") as NSString).integerValue
        let h = ((kv["height"] ?? "") as NSString).integerValue
        if w > 0 && h > 0 { bits.append("\(w)×\(h)") }
        let fps = fpsFromRational(kv["r_frame_rate"] ?? "")
        if fps > 0 { bits.append(String(format: "%.2f fps", fps)) }
        let codec = kv["codec_name"] ?? ""
        if !codec.isEmpty { bits.append(codec) }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    private static func fpsFromRational(_ rational: String) -> Double {
        if rational.isEmpty { return 0 }
        let parts = rational.components(separatedBy: "/")
        if parts.count == 2 {
            let num = (parts[0] as NSString).doubleValue
            let den = (parts[1] as NSString).doubleValue
            return den > 0 ? num / den : 0
        }
        return (rational as NSString).doubleValue
    }

    private static func tail(of s: String, lines n: Int) -> String {
        let keep = s.components(separatedBy: "\n").filter { !$0.isEmpty }
        let start = max(0, keep.count - n)
        return keep[start...].joined(separator: "\n")
    }
}
