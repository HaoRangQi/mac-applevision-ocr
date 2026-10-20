import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

// MARK: - 运行参数与模型

enum JobState: String {
    case pending = "等待"
    case running = "识别中"
    case done = "完成"
    case failed = "失败"
    case cancelled = "已取消"
}

/// 队列里的一个待识别文件
struct OCRJob: Identifiable {
    let id = UUID()
    let url: URL
    var outPath: String
    var pageCount: Int = 1
    var state: JobState = .pending
    var chars: Int = 0
    var seconds: Double = 0
    var message: String = ""
    var isPDF: Bool { url.pathExtension.lowercased() == "pdf" }
}

final class OCRModel: ObservableObject {
    @Published var url: URL?
    @Published var pageCount = 0
    @Published var pageRange = ""
    @Published var mode = "layout"
    @Published var rotate = 0
    /// 识别路数 1-3：取 3.5 / 4.5 / 5.6 三个倍率里的前 N 个（仅 PDF 有效）
    @Published var passes = 3
    @Published var wrap = false
    @Published var text = ""
    @Published var status = "把 PDF 或图片拖进来"
    @Published var progress = 0.0
    @Published var running = false
    @Published var log = ""
    @Published var targeted = false
    // 输出目的地：默认写文件（大文本在界面里渲染会卡）
    @Published var writeToFile = true
    @Published var outPath = ""
    @Published var resultPath = ""
    @Published var resultChars = 0
    @Published var preview = ""
    // 批量队列
    @Published var jobs: [OCRJob] = []
    @Published var batchOutDir = ""
    @Published var batchRunning = false
    @Published var overallProgress = 0.0
    @Published var selectedJobID: UUID?
    // 外观：auto / light / dark（持久化到 UserDefaults）
    @Published var appearance: String = UserDefaults.standard.string(forKey: "appearance") ?? "auto"

    /// 界面里最多预览多少字，再多只写到文件里
    static let previewChars = 2000

    /// 预览用字符数上限，防止把整本书读进来渲染
    private var previewLimit: Int { Self.previewChars }

    private var proc: Process?
    private var started = Date()
    private var buf = ""
    private var donePages = 0
    private var totalUnits = 1
    private var totalPages = 0
    private var currentPass = 1
    private var totalPasses = 1
    private var outData = Data()
    private var toFile = false
    private var stopRequested = false
    private var runningIndex = 0

    static weak var shared: OCRModel?

    init() { OCRModel.shared = self }

    var canRun: Bool { !jobs.isEmpty && !running }
    var hasPDF: Bool { jobs.contains { $0.isPDF } }
    var isBatch: Bool { jobs.count > 1 }

    func setAppearance(_ v: String) {
        appearance = v
        UserDefaults.standard.set(v, forKey: "appearance")
        Self.applyAppearance(v)
    }

    /// 把外观应用到整个应用（窗口、菜单、面板都会跟着变）
    static func applyAppearance(_ v: String) {
        switch v {
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default:      NSApplication.shared.appearance = nil
        }
    }

    static func pythonPath() -> String? {
        let home = NSHomeDirectory()
        let cands = [
            "\(home)/.workbuddy-ai/binaries/python/versions/3.13.12/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        return cands.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func packageRoot() -> String? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("applevision_ocr").path,
           FileManager.default.fileExists(atPath: r) { return Bundle.main.resourceURL?.path }
        let p = NSHomeDirectory() + "/.local/share/applevision-ocr"
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    static func enginePath() -> String? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("ocrvision").path,
           FileManager.default.fileExists(atPath: r) { return r }
        let p = NSHomeDirectory() + "/.local/share/applevision-ocr/ocrvision"
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// 加入队列（可多个）；只有一个文件时保持原来的「当前文件」体验
    func add(_ urls: [URL]) {
        let supported: Set<String> = ["pdf", "png", "jpg", "jpeg", "tif", "tiff", "heic", "bmp", "gif", "webp"]
        var added = 0
        for u in urls {
            let ext = u.pathExtension.lowercased()
            guard supported.contains(ext) else { continue }
            guard FileManager.default.fileExists(atPath: u.path) else { continue }
            if jobs.contains(where: { $0.url.path == u.path }) { continue }
            let pc = ext == "pdf" ? (PDFDocument(url: u)?.pageCount ?? 0) : 1
            jobs.append(OCRJob(url: u, outPath: Self.defaultOutPath(for: u), pageCount: pc))
            added += 1
        }
        guard added > 0 else { return }
        if jobs.count == 1 {
            pageRange = ""
            text = ""
            log = ""
            progress = 0
            preview = ""
            resultChars = 0
            select(jobs[0])
            status = "已载入 \(jobs[0].url.lastPathComponent)\(jobs[0].isPDF ? " · \(jobs[0].pageCount) 页" : "")"
        } else {
            text = ""
            preview = ""
            resultPath = ""
            resultChars = 0
            selectedJobID = jobs.last?.id
            status = "已加入 \(jobs.count) 个文件，点击开始识别"
        }
    }

    func load(_ u: URL) { add([u]) }

    /// 选中队列里的某个文件，右侧展示它的结果
    func select(_ job: OCRJob) {
        selectedJobID = job.id
        url = job.url
        pageCount = job.pageCount
        outPath = job.outPath
        resultPath = job.outPath
        resultChars = job.chars
        text = ""
        preview = job.state == .done ? Self.headOfFile(job.outPath, limit: previewLimit) : ""
        if job.state == .done {
            let name = (job.outPath as NSString).lastPathComponent
            status = "已保存 \(name)" + (job.chars > 0 ? " · \(job.chars) 字" : "")
        } else if job.state == .running {
            status = "识别中…"
        } else {
            status = "等待识别"
        }
    }

    /// 批量模式下每个文件的输出路径：优先 batchOutDir，否则源文件同目录
    func outPath(for u: URL) -> String {
        let dir = batchOutDir.trimmingCharacters(in: .whitespaces)
        let base = u.deletingPathExtension().lastPathComponent
        if !dir.isEmpty {
            let d = (dir as NSString).expandingTildeInPath
            return (d as NSString).appendingPathComponent(base + ".txt")
        }
        return Self.defaultOutPath(for: u)
    }

    func pickBatchOutDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择批量输出的目录"
        if panel.runModal() == .OK, let u = panel.url { batchOutDir = u.path }
    }

    func clearQueue() {
        guard !running else { return }
        jobs.removeAll()
        url = nil
        pageCount = 0
        preview = ""
        resultPath = ""
        resultChars = 0
        text = ""
        outPath = ""
        overallProgress = 0
        selectedJobID = nil
        status = "把 PDF 或图片拖进来"
    }

    func removeJob(_ job: OCRJob) {
        guard !running else { return }
        jobs.removeAll { $0.id == job.id }
        if jobs.isEmpty {
            clearQueue()
        } else if selectedJobID == job.id, let f = jobs.first {
            select(f)
        }
    }

    /// 默认输出路径：与源文件同目录同名，后缀换成 .txt；无后缀则追加 .txt
    static func defaultOutPath(for u: URL) -> String {
        if u.pathExtension.isEmpty {
            return u.path + ".txt"
        }
        return u.deletingPathExtension().appendingPathExtension("txt").path
    }

    /// 选择输出文件位置（默认预填同名 .txt）
    func pickOutPath() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let name = outPath.isEmpty
            ? (url?.deletingPathExtension().lastPathComponent ?? "ocr") + ".txt"
            : (outPath as NSString).lastPathComponent
        panel.nameFieldStringValue = name
        let dir = outPath.isEmpty
            ? url?.deletingLastPathComponent()
            : URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath).deletingLastPathComponent()
        if let dir { panel.directoryURL = dir }
        if panel.runModal() == .OK, let u = panel.url { outPath = u.path }
    }

    func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "选择 PDF 或图片（可多选，加入队列）"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    /// 开始识别：单文件沿用原体验，多文件按队列逐个处理
    func run() {
        guard !jobs.isEmpty else {
            status = "请先选择文件"
            return
        }
        // 单文件：把界面上的输出路径同步进队列项
        if jobs.count == 1, writeToFile {
            let dest = outPath.trimmingCharacters(in: .whitespaces)
            if dest.isEmpty {
                status = "请填写输出路径"
                return
            }
            let expanded = (dest as NSString).expandingTildeInPath
            let parent = (expanded as NSString).deletingLastPathComponent
            if !FileManager.default.fileExists(atPath: parent) {
                status = "输出目录不存在：\(parent)"
                return
            }
            if !FileManager.default.isWritableFile(atPath: parent) {
                status = "目录不可写：\(parent)"
                return
            }
            jobs[0].outPath = expanded
        }
        // 全部已结束则整体重跑；否则只跑还没完成的
        if jobs.allSatisfy({ $0.state == .done || $0.state == .failed || $0.state == .cancelled }) {
            for i in jobs.indices {
                jobs[i].state = .pending
                jobs[i].chars = 0
                jobs[i].message = ""
            }
        }
        stopRequested = false
        batchRunning = true
        overallProgress = 0
        text = ""
        preview = ""
        log = ""
        startNext()
    }

    /// 取下一个待处理文件；没有就收尾
    private func startNext() {
        guard !stopRequested else {
            batchRunning = false
            running = false
            return
        }
        guard let idx = jobs.firstIndex(where: { $0.state == .pending }) else {
            batchRunning = false
            running = false
            proc = nil
            progress = 1
            overallProgress = 1
            let done = jobs.filter { $0.state == .done }.count
            let fail = jobs.filter { $0.state == .failed }.count
            if jobs.count > 1 {
                status = fail > 0 ? "全部完成：成功 \(done) · 失败 \(fail)" : "全部完成：\(done) 个文件"
            }
            return
        }
        runningIndex = idx
        selectedJobID = jobs[idx].id
        url = jobs[idx].url
        pageCount = jobs[idx].pageCount
        jobs[idx].state = .running
        if jobs.count > 1 {
            jobs[idx].outPath = outPath(for: jobs[idx].url)
        }
        runCurrent(index: idx)
    }

    /// 跑队列里的第 index 个文件
    private func runCurrent(index: Int) {
        guard let url, let py = Self.pythonPath(), let root = Self.packageRoot() else {
            running = false
            if index < jobs.count {
                jobs[index].state = .failed
                jobs[index].message = "找不到识别引擎"
            }
            startNext()
            return
        }
        running = true
        text = ""
        preview = ""
        resultChars = 0
        log = ""
        buf = ""
        outData = Data()
        donePages = 0
        progress = 0
        started = Date()
        status = jobs.count > 1
            ? "第 \(index + 1)/\(jobs.count) 个：\(url.lastPathComponent)"
            : "正在识别…"

        var args = ["-m", "applevision_ocr", url.path, "--mode", mode]
        let pr = pageRange.trimmingCharacters(in: .whitespaces)
        if !pr.isEmpty { args += ["-p", pr] }
        // 图片只跑一路（引擎侧也强制如此），PDF 才按用户选的路数投票
        let isPDF = url.pathExtension.lowercased() == "pdf"
        let nPasses = isPDF ? max(1, min(3, passes)) : 1
        args += ["--passes", String(nPasses)]
        if rotate != 0 { args += ["--rot", String(rotate)] }
        if wrap { args += ["--wrap", "76"] }

        // 批量时强制落盘：多个结果没法共用一个编辑器
        toFile = writeToFile || jobs.count > 1
        if toFile {
            let expanded = (jobs[index].outPath as NSString).expandingTildeInPath
            let parent = (expanded as NSString).deletingLastPathComponent
            // 先校验目录，别等识别完才发现写不进去
            if !FileManager.default.fileExists(atPath: parent) {
                running = false
                jobs[index].state = .failed
                jobs[index].message = "输出目录不存在"
                startNext()
                return
            }
            if !FileManager.default.isWritableFile(atPath: parent) {
                running = false
                jobs[index].state = .failed
                jobs[index].message = "目录不可写"
                startNext()
                return
            }
            args += ["-o", expanded]
            resultPath = expanded
        }

        let pages = expectedPages()
        totalPages = pages
        totalUnits = max(1, pages * nPasses)
        currentPass = 1
        totalPasses = nPasses

        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = root
        if let engine = Self.enginePath() { env["APPLEVISION_OCR_ENGINE"] = engine }
        p.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            if self?.toFile == true {
                // 写文件模式：全文已由 CLI 落盘，这里只把管道读干，不做缓存
                return
            }
            DispatchQueue.main.async { self?.outData.append(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else {
                h.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { self?.consume(s) }
        }
        p.terminationHandler = { [weak self] proc in
            let rest = outPipe.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async { self?.finish(rest, code: proc.terminationStatus, index: index) }
        }

        do {
            try p.run()
            proc = p
        } catch {
            running = false
            if index < jobs.count {
                jobs[index].state = .failed
                jobs[index].message = "启动失败"
            }
            startNext()
        }
    }

    /// 期望处理的页数：交给 Python 用同一套页码语法解析，
    /// 保证进度分母和实际会识别的页数一致（多段/倒数/越界都算得对）。
    private func expectedPages() -> Int {
        guard let py = Self.pythonPath(), let root = Self.packageRoot(), let url else {
            return max(1, pageCount)
        }
        let pr = pageRange.trimmingCharacters(in: .whitespaces)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        var a = ["-m", "applevision_ocr", url.path, "--page-count"]
        if !pr.isEmpty { a += ["-p", pr] }
        p.arguments = a
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = root
        if let engine = Self.enginePath() { env["APPLEVISION_OCR_ENGINE"] = engine }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let n = Int(s), n > 0 {
                return n
            }
        } catch {
            // 查询失败就退回整本页数
        }
        return max(1, pageCount)
    }

    /// 总进度 =（已完成文件数 + 当前文件进度）/ 文件总数
    private func overallProgressValue() -> Double {
        guard !jobs.isEmpty else { return progress }
        let finished = jobs.filter { $0.state == .done || $0.state == .failed || $0.state == .cancelled }.count
        return min(1, (Double(finished) + progress) / Double(jobs.count))
    }

    private func consume(_ s: String) {
        buf += s
        while let i = buf.firstIndex(of: "\n") {
            let line = String(buf[buf.startIndex..<i]).trimmingCharacters(in: .whitespaces)
            buf = String(buf[buf.index(after: i)...])
            guard !line.isEmpty else { continue }
            log += line + "\n"
            let prefix = jobs.count > 1 ? "第 \(runningIndex + 1)/\(jobs.count) 个 · " : ""
            if line.hasPrefix("识别 pass ") {
                // 「识别 pass 2/3 (scale=4.5)」→ 记下第几路，好在状态里显示
                let head = line.dropFirst("识别 pass ".count)
                let parts = head.split(separator: "/", maxSplits: 1)
                if parts.count == 2 {
                    currentPass = Int(parts[0]) ?? 1
                    totalPasses = Int(parts[1].prefix(while: { !$0.isWhitespace })) ?? 1
                }
                status = prefix + "第 \(currentPass)/\(totalPasses) 路识别…"
            }
            if line.hasPrefix("page ") {
                donePages += 1
                progress = min(0.99, Double(donePages) / Double(totalUnits))
                overallProgress = overallProgressValue()
                let page = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                let passNote = totalPasses > 1 ? " · 第 \(currentPass)/\(totalPasses) 路" : ""
                status = prefix + "识别第 \(page)/\(totalPages) 页\(passNote)…"
            }
            // 写文件模式下 CLI 会报告「→ 路径 (N 字)」，取出字数
            if toFile, line.hasPrefix("→ "),
               let r = line.range(of: #"(\d+)\s*字"#, options: .regularExpression) {
                let digits = line[r].prefix(while: { $0.isNumber })
                resultChars = Int(digits) ?? 0
            }
        }
        if log.count > 4000 { log = String(log.suffix(2000)) }
    }

    private func finish(_ rest: Data, code: Int32, index: Int) {
        // 被取消的进程：标成已取消，不再继续队列
        if stopRequested {
            if index < jobs.count { jobs[index].state = .cancelled }
            running = false
            proc = nil
            return
        }
        let elapsed = Date().timeIntervalSince(started)
        let secs = String(format: "%.1f", elapsed)
        running = false
        progress = 1
        if index < jobs.count { jobs[index].seconds = elapsed }

        if toFile {
            // CLI 已在 stderr 里报告「→ 路径 (N 字)」，consume() 已解析出来
            let charsNote = resultChars > 0 ? " · \(resultChars) 字" : ""
            if code == 0 && !resultPath.isEmpty {
                preview = Self.headOfFile(resultPath, limit: previewLimit)
                let name = (resultPath as NSString).lastPathComponent
                status = "已保存 \(name)\(charsNote) · 用时 \(secs) 秒"
                if index < jobs.count { jobs[index].state = .done; jobs[index].chars = resultChars }
            } else if code == 0 {
                status = "没有识别到文字"
                if index < jobs.count { jobs[index].state = .done; jobs[index].chars = 0 }
            } else {
                status = "识别失败（退出码 \(code)）"
                if index < jobs.count { jobs[index].state = .failed; jobs[index].message = "退出码 \(code)" }
            }
            proc = nil
            overallProgress = overallProgressValue()
            startNext()
            return
        }

        outData.append(rest)
        var s = String(data: outData, encoding: .utf8) ?? ""
        outData = Data()
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        text = s
        if code == 0 && !s.isEmpty {
            status = "完成 · \(s.count) 字 · 用时 \(secs) 秒"
            if index < jobs.count { jobs[index].state = .done; jobs[index].chars = s.count }
        } else if code == 0 {
            status = "没有识别到文字"
            if index < jobs.count { jobs[index].state = .done; jobs[index].chars = 0 }
        } else {
            status = "识别失败（退出码 \(code)）"
            if index < jobs.count { jobs[index].state = .failed; jobs[index].message = "退出码 \(code)" }
        }
        proc = nil
        overallProgress = overallProgressValue()
        startNext()
    }

    func cancel() {
        stopRequested = true
        proc?.terminate()
        running = false
        batchRunning = false
        if runningIndex < jobs.count, jobs[runningIndex].state == .running {
            jobs[runningIndex].state = .cancelled
        }
        status = "已取消"
        proc = nil
    }

    func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let base = url?.deletingPathExtension().lastPathComponent ?? "ocr"
        panel.nameFieldStringValue = base + ".txt"
        if panel.runModal() == .OK, let u = panel.url {
            try? text.write(to: u, atomically: true, encoding: .utf8)
            status = "已保存到 \(u.lastPathComponent)"
        }
    }

    func copyAll() {
        // 写文件模式复制整份文件；界面模式复制界面里的文本
        let s = (!resultPath.isEmpty && FileManager.default.fileExists(atPath: resultPath))
            ? Self.readFile(resultPath)
            : text
        guard !s.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        status = "已复制到剪贴板"
    }

    func revealInFinder() {
        guard !resultPath.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: resultPath)])
    }

    func openResult() {
        guard !resultPath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: resultPath))
    }

    /// 只读文件前 limit 个字符做预览，不把整份文本读进内存渲染
    static func headOfFile(_ path: String, limit: Int) -> String {
        guard let h = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? h.close() }
        // UTF-8 一个字符最多 4 字节，多读一些再截，避免边界切断
        let raw = (try? h.read(upToCount: max(limit * 4, 64))) ?? Data()
        var s = String(decoding: raw, as: UTF8.self)
        if s.count > limit { s = String(s.prefix(limit)) }
        if s.hasSuffix("\u{FFFD}") { s.removeLast() }   // 边界切断产生的替换符
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func readFile(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }
}

// MARK: - 界面

struct ContentView: View {
    @ObservedObject var m: OCRModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            editor
        }
        .frame(minWidth: 940, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // 左侧：文件、参数、操作
    private var sidebar: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AppleVisionOCR").font(.system(size: 19, weight: .semibold))
                        Text("本地识别 · 不上传").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Picker("", selection: Binding(get: { m.appearance }, set: { m.setAppearance($0) })) {
                        Text("跟随系统").tag("auto")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 92)
                    .help("外观")
                }

                dropZone

                if m.jobs.count > 1 {
                    queueList
                }

            VStack(alignment: .leading, spacing: 10) {
                Text("识别设置").font(.caption).fontWeight(.medium).foregroundStyle(.secondary)

                HStack {
                    Text("页码范围").frame(width: 62, alignment: .leading)
                    TextField("全部", text: $m.pageRange)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!m.hasPDF)
                }
                .font(.callout)

                HStack {
                    Text("输出").frame(width: 62, alignment: .leading)
                    Picker("", selection: $m.mode) {
                        Text("还原段落").tag("layout")
                        Text("逐行").tag("text")
                        Text("JSON").tag("json")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .font(.callout)

                HStack {
                    Text("旋转").frame(width: 62, alignment: .leading)
                    Picker("", selection: $m.rotate) {
                        Text("0°").tag(0)
                        Text("90°").tag(90)
                        Text("-90°").tag(-90)
                        Text("180°").tag(180)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .font(.callout)

                // 识别路数：1 最快、3 最准，用户自己拖
                HStack(spacing: 8) {
                    Text("识别路数").frame(width: 62, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { Double(m.passes) },
                            set: { m.passes = Int($0.rounded()) }
                        ),
                        in: 1...3, step: 1
                    )
                    .disabled(!m.hasPDF)
                    Text("\(m.passes) 路")
                        .font(.callout.monospacedDigit())
                        .frame(width: 32, alignment: .trailing)
                }
                .font(.callout)
                Text(m.hasPDF || m.jobs.isEmpty
                     ? "1 路最快 · 2 路折中 · 3 路最准（约 3 倍耗时）"
                     : "图片固定单路，多路投票仅 PDF 有效")
                    .font(.caption2).foregroundStyle(.tertiary)

                Toggle("按 76 字折行", isOn: $m.wrap)
                    .font(.callout)
            }

            // 结果去哪：默认写文件，避免大文本在界面里渲染卡顿
            VStack(alignment: .leading, spacing: 8) {
                Text("结果").font(.caption).fontWeight(.medium).foregroundStyle(.secondary)

                if m.jobs.count > 1 {
                    HStack(spacing: 6) {
                        TextField("输出目录（空 = 各自源目录）", text: $m.batchOutDir)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout)
                        Button("选择…") { m.pickBatchOutDir() }
                            .controlSize(.small)
                    }
                    Text("批量：每个文件保存为同名 .txt")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Picker("", selection: $m.writeToFile) {
                        Text("保存到文件").tag(true)
                        Text("界面显示").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if m.writeToFile {
                        HStack(spacing: 6) {
                            TextField("输出路径", text: $m.outPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.callout)
                                .disabled(m.url == nil)
                            Button("选择…") { m.pickOutPath() }
                                .controlSize(.small)
                                .disabled(m.url == nil)
                        }
                        Text("默认与源文件同名，存为 .txt")
                            .font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        Text("文本较大时界面可能卡顿")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            if m.running {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: m.overallProgress)
                    Text(m.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Button("取消") { m.cancel() }.controlSize(.small)
                }
            } else {
                Button {
                    m.run()
                } label: {
                    Text(m.jobs.count > 1 ? "开始识别（\(m.jobs.count) 个）" : "开始识别")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!m.canRun)
                .keyboardShortcut("r", modifiers: .command)

                Text(m.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            }
            .padding(18)
        }
        .frame(width: 316)
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: m.jobs.isEmpty ? "arrow.down.doc" : (m.jobs.count > 1 ? "square.stack.3d.up.fill" : "doc.text.fill"))
                .font(.system(size: 26))
                .foregroundStyle(m.jobs.isEmpty ? Color.secondary : Color.accentColor)
            if m.jobs.count > 1 {
                Text("\(m.jobs.count) 个文件").font(.callout).fontWeight(.medium)
                Text("已加入队列，点开始识别").font(.caption).foregroundStyle(.secondary)
            } else if let u = m.url {
                Text(u.lastPathComponent)
                    .font(.callout).fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .help(u.lastPathComponent)
                Text(u.pathExtension.lowercased() == "pdf" ? "\(m.pageCount) 页" : "图片")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("拖入 PDF 或图片").font(.callout)
                Text("支持多选 / 多文件排队").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 112)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    m.targeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: m.targeted ? 2 : 1, dash: [6, 4])
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { m.pickFile() }
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { m.targeted }, set: { m.targeted = $0 })) { providers in
            let group = DispatchGroup()
            var urls: [URL] = []
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { u, _ in
                    if let u { DispatchQueue.main.async { urls.append(u) } }
                    group.leave()
                }
            }
            group.notify(queue: .main) { m.add(urls) }
            return true
        }
    }

    // 队列列表：每个文件的进度 / 结果
    private var queueList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("队列 \(m.jobs.count)").font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                Spacer()
                Button("清空") { m.clearQueue() }
                    .controlSize(.small)
                    .disabled(m.running)
            }
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(m.jobs) { job in
                        jobRow(job)
                    }
                }
            }
            .frame(maxHeight: 132)
        }
    }

    private func jobRow(_ job: OCRJob) -> some View {
        HStack(spacing: 6) {
            Image(systemName: jobIcon(job.state))
                .font(.caption)
                .foregroundStyle(jobColor(job.state))
                .frame(width: 14)
            Text(job.url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(job.state == .done ? "\(job.chars) 字" : job.state.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(m.selectedJobID == job.id ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { if job.state == .done { m.select(job) } }
        .help(job.outPath)
    }

    private func jobIcon(_ s: JobState) -> String {
        switch s {
        case .pending: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private func jobColor(_ s: JobState) -> Color {
        switch s {
        case .pending: return .secondary
        case .running: return .accentColor
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    // 右侧：结果
    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("识别结果").font(.callout).fontWeight(.medium)
                Spacer()
                if !m.text.isEmpty {
                    Text("\(m.text.count) 字").font(.caption).foregroundStyle(.secondary)
                } else if !m.preview.isEmpty && m.resultChars > 0 {
                    Text("\(m.resultChars) 字").font(.caption).foregroundStyle(.secondary)
                }
                Button("复制") { m.copyAll() }
                    .disabled(m.text.isEmpty && m.preview.isEmpty)
                if m.writeToFile && !m.resultPath.isEmpty {
                    Button("打开") { m.openResult() }
                    Button("访达") { m.revealInFinder() }
                } else {
                    Button("保存…") { m.save() }
                        .disabled(m.text.isEmpty)
                        .keyboardShortcut("s", modifiers: .command)
                }
                if m.running {
                    Button("取消") { m.cancel() }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if m.running {
                VStack(spacing: 10) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 38))
                        .foregroundStyle(.tertiary)
                    Text("识别中…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !m.preview.isEmpty {
                // 写文件模式：只预览前若干字，附文件位置
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text.fill")
                                .foregroundStyle(Color.accentColor)
                            Text(m.resultPath)
                                .font(.callout)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                            Button("在访达中显示") { m.revealInFinder() }
                                .controlSize(.small)
                        }
                        Text("以下为前 \(m.preview.count) 字预览：")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(m.preview)
                            .font(.system(size: 13, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(14)
                }
            } else if m.text.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 38))
                        .foregroundStyle(.tertiary)
                    Text("结果会显示在这里")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: .constant(m.text))
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 入口

@main
struct AppleVisionOCRApp: App {
    let model = OCRModel()

    init() {
        // 供命令行自检：OCRKit.app/Contents/MacOS/OCRKit --selftest 文件.pdf
        if let i = CommandLine.arguments.firstIndex(of: "--selftest"),
           i + 1 < CommandLine.arguments.count {
            SelfTest.run(path: CommandLine.arguments[i + 1])
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--runmodel"),
           i + 1 < CommandLine.arguments.count {
            SelfTest.runModel(path: CommandLine.arguments[i + 1])
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--runbatch") {
            let rest = Array(CommandLine.arguments[(i + 1)...])
            if rest.count >= 2 {
                SelfTest.runBatch(outDir: rest[0], files: Array(rest[1...]))
                exit(0)
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"),
           i + 1 < CommandLine.arguments.count {
            SelfTest.snapshot(to: CommandLine.arguments[i + 1])
            exit(0)
        }
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("AppleVisionOCR") {
            ContentView(m: model)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开…") { model.pickFile() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .saveItem) {
                Button("导出为文本…") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        OCRModel.applyAppearance(UserDefaults.standard.string(forKey: "appearance") ?? "auto")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async { OCRModel.shared?.add(urls) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum SelfTest {
    static func runModel(path: String) {
        _ = NSApplication.shared
        let m = OCRModel()
        m.load(URL(fileURLWithPath: path))
        m.passes = 1
        // OCRDISPLAY=1 → 界面显示模式；否则走默认的写文件模式
        if ProcessInfo.processInfo.environment["OCRDISPLAY"] == "1" { m.writeToFile = false }
        // OCROUT=路径 → 覆盖默认输出路径（用于校验路径检查）
        if let o = ProcessInfo.processInfo.environment["OCROUT"] { m.outPath = o }
        if let pg = ProcessInfo.processInfo.environment["OCRPAGES"] {
            m.pageRange = pg
            m.passes = 3
        }
        // OCRPASSES=2 → 覆盖路数，用来验证滑杆对应的进度分母
        if let np = ProcessInfo.processInfo.environment["OCRPASSES"] {
            m.passes = Int(np) ?? 1
        }
        m.run()
        let deadline = Date().addingTimeInterval(180)
        // 每 2 秒打印一次进度，用于无界面验证进度条是否真的在走
        let ticker = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            guard m.running else { return }
            print(String(format: "进度 %3.0f%% · %@", m.progress * 100, m.status))
        }
        while m.running && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        ticker.invalidate()
        print(String(format: "进度 %3.0f%% · %@", m.progress * 100, m.status))
        print("toFile: \(m.writeToFile)")
        print("status: \(m.status)")
        print("chars: \(m.text.count)")
        print("progress: \(m.progress)")
        if !m.resultPath.isEmpty {
            print("result: \(m.resultPath)")
            print("resultChars: \(m.resultChars)")
            print("previewCount: \(m.preview.count)")
            print("preview: \(m.preview.prefix(40).replacingOccurrences(of: "\n", with: " | "))")
        }
        print("head: \(m.text.prefix(60).replacingOccurrences(of: "\n", with: " | "))")
    }

    /// 无界面跑一遍批量队列：--runbatch <输出目录> <文件1> <文件2> …
    static func runBatch(outDir: String, files: [String]) {
        _ = NSApplication.shared
        let m = OCRModel()
        m.passes = 1
        m.batchOutDir = outDir
        m.add(files.map { URL(fileURLWithPath: $0) })
        print("queued: \(m.jobs.count)")
        m.run()
        let deadline = Date().addingTimeInterval(300)
        let ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            guard m.running else { return }
            print(String(format: "总进度 %3.0f%% · %@", m.overallProgress * 100, m.status))
        }
        while m.running && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        ticker.invalidate()
        print("status: \(m.status)")
        print(String(format: "overall: %.2f", m.overallProgress))
        for j in m.jobs {
            print("job \(j.state.rawValue) \(j.chars)字 \(j.url.lastPathComponent) -> \(j.outPath) \(j.message)")
        }
    }

    /// 截图用的示例输入：固定使用仓库内的 dd.png（知乎截图）及其 PDF 版，不引用任何真实书籍。
    /// 用 PDF 是为了让「多路投票」这类仅 PDF 生效的设置能在截图里如实展示。
    /// 由输出路径反推仓库根：`--snapshot docs/screenshot.png` → `<repo>/tests/fixtures/showcase.pdf`
    static func fixturePath(forOutput path: String) -> String {
        URL(fileURLWithPath: path)
            .deletingLastPathComponent()   // <repo>/docs
            .deletingLastPathComponent()   // <repo>
            .appendingPathComponent("tests/fixtures/showcase.pdf")
            .path
    }

    static func snapshot(to path: String) {
        _ = NSApplication.shared
        let m = OCRModel()
        let fixture = Self.fixturePath(forOutput: path)   // tests/fixtures/showcase.pdf (= dd.png)
        m.url = URL(fileURLWithPath: fixture)
        m.pageCount = 1
        m.status = "已载入 showcase.pdf · 1 页"
        if ProcessInfo.processInfo.environment["OCRSNAP"] == "run" {
            m.running = true
            m.progress = 0.42
            m.status = "识别第 1 页 · 第 1/3 路…"
        }
        if ProcessInfo.processInfo.environment["OCRSNAP"] == "empty" {
            m.url = nil
            m.pageCount = 0
            m.status = "把 PDF 或图片拖进来"
        }
        if ProcessInfo.processInfo.environment["OCRSNAP"] == "batch" {
            // 批量队列模式：1 个已完成、1 个识别中、1 个等待
            let a = URL(fileURLWithPath: fixture)
            let b = a.deletingLastPathComponent().appendingPathComponent("sample.png")
            let c = URL(fileURLWithPath: "/tmp/合同扫描件.png")
            var j1 = OCRJob(url: a, outPath: OCRModel.defaultOutPath(for: a), pageCount: 1)
            j1.state = JobState.done
            j1.chars = previewBody.count
            var j2 = OCRJob(url: b, outPath: OCRModel.defaultOutPath(for: b), pageCount: 1)
            j2.state = JobState.running
            let j3 = OCRJob(url: c, outPath: OCRModel.defaultOutPath(for: c), pageCount: 1)
            m.jobs = [j1, j2, j3]
            m.selectedJobID = j1.id
            m.url = a
            m.pageCount = 1
            m.running = true
            m.progress = 0.6
            m.overallProgress = 0.53
            m.status = "第 2/3 个 · 识别第 3/8 页…"
            m.writeToFile = true
        } else if ProcessInfo.processInfo.environment["OCRSNAP"] == "display" {
            // 界面显示模式
            m.writeToFile = false
            m.text = previewBody
        } else {
            // 默认的写文件模式
            m.writeToFile = true
            let out = URL(fileURLWithPath: fixture).deletingPathExtension().appendingPathExtension("txt").path
            m.outPath = out
            m.resultPath = out
            m.resultChars = previewBody.count
            m.status = "已保存 showcase.txt · \(previewBody.count) 字 · 用时 1.8 秒"
            m.preview = previewBody
        }
        let snapAppearance = ProcessInfo.processInfo.environment["OCRSNAPAPPEARANCE"]
        if let ap = snapAppearance { m.appearance = ap }
        let v = NSHostingView(rootView: ContentView(m: m))
        if let ap = snapAppearance {
            v.appearance = NSAppearance(named: ap == "dark" ? .darkAqua : .aqua)
        }
        v.frame = CGRect(x: 0, y: 0, width: 960, height: 660)
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { print("no rep"); return }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let d = rep.representation(using: .png, properties: [:]) {
            try? d.write(to: URL(fileURLWithPath: path))
            print("saved \(path)")
        }
    }

    /// 截图用的示例文本：固定使用 dd.png（知乎截图）的识别结果，不引用任何真实书籍内容。
    static let previewBody = """
    能不能告诉我，中国的税负在世界是什么水平？

    重水轮回立
    2325人赞同了该回答〉
    朋友一家移民美国。他妈在国内是典型的安分守己，相信**的那种人。去到美国后，一开始购物发现
    结账跟商品价格对不上，儿子提醒后才知道税费被单独写出来。于是乎就开始BB税费怎么这么高之
    类的。过了一段时间，他妈已经开始在他们的小区宣传说要换掉他们当地的州长了，说他们交的税被
    乱花掉，浪费掉之类的了。
    编辑于 2026-03-11 11:43
    4 赞同2320 | • 92 条评论 | ★ 131 | →分享＋… |  | 收起へ
    轰轰烈烈的医疗反腐为何突然沉寂？背后原因是什么？
    平平安安：集采了。然后腐败在基层没有土壤，然后真正腐败都在高层了。一个大学同学说的。医
    院集采两款伽马刀，有一款就是不好用，大家怎么反应都没用。好用的…阅读全文～
    A 赞同1.3万 | • 641条评论 | ★ 1652 |  | →分享⋯
    """

    static func run(path: String) {
        guard let py = OCRModel.pythonPath(), let root = OCRModel.packageRoot() else {
            print("no python/package"); return
        }
        print("python: \(py)")
        print("package: \(root)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = ["-m", "applevision_ocr", path, "--no-vote"]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = root
        if let engine = OCRModel.enginePath() { env["APPLEVISION_OCR_ENGINE"] = engine }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { print("run failed: \(error)"); return }
        p.waitUntilExit()
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print("exit: \(p.terminationStatus)")
        print("stderr: \(e.prefix(300))")
        print("stdout head:")
        print(o.split(separator: "\n").prefix(6).joined(separator: "\n"))
    }
}
