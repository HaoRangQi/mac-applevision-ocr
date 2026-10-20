import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

// MARK: - 运行参数与模型

final class OCRModel: ObservableObject {
    @Published var url: URL?
    @Published var pageCount = 0
    @Published var pageRange = ""
    @Published var mode = "layout"
    @Published var rotate = 0
    @Published var vote = true
    @Published var wrap = false
    @Published var text = ""
    @Published var status = "把 PDF 或图片拖进来"
    @Published var progress = 0.0
    @Published var running = false
    @Published var log = ""
    @Published var targeted = false

    private var proc: Process?
    private var started = Date()
    private var buf = ""
    private var donePages = 0
    private var totalUnits = 1
    private var outData = Data()

    static weak var shared: OCRModel?

    init() { OCRModel.shared = self }

    var canRun: Bool { url != nil && !running }

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

    func load(_ u: URL) {
        url = u
        pageRange = ""
        text = ""
        log = ""
        progress = 0
        if u.pathExtension.lowercased() == "pdf",
           let doc = PDFDocument(url: u) {
            pageCount = doc.pageCount
            status = "已载入 \(u.lastPathComponent) · \(pageCount) 页"
        } else {
            pageCount = 1
            status = "已载入 \(u.lastPathComponent)"
        }
    }

    func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = false
        panel.message = "选择 PDF 或图片"
        if panel.runModal() == .OK, let u = panel.url { load(u) }
    }

    func run() {
        guard let url, let py = Self.pythonPath(), let root = Self.packageRoot() else {
            status = "找不到识别引擎，请先运行 make install"
            return
        }
        running = true
        text = ""
        log = ""
        buf = ""
        donePages = 0
        progress = 0
        started = Date()
        status = "正在识别…"

        var args = ["-m", "applevision_ocr", url.path, "--mode", mode]
        let pr = pageRange.trimmingCharacters(in: .whitespaces)
        if !pr.isEmpty { args += ["-p", pr] }
        if !vote { args += ["--no-vote"] }
        if rotate != 0 { args += ["--rot", String(rotate)] }
        if wrap { args += ["--wrap", "76"] }

        let pages = expectedPages()
        let passes = (vote && url.pathExtension.lowercased() == "pdf") ? 3 : 1
        totalUnits = max(1, pages * passes)

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
            DispatchQueue.main.async { self?.finish(rest, code: proc.terminationStatus) }
        }

        do {
            try p.run()
            proc = p
        } catch {
            running = false
            status = "启动失败：\(error.localizedDescription)"
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

    private func consume(_ s: String) {
        buf += s
        while let i = buf.firstIndex(of: "\n") {
            let line = String(buf[buf.startIndex..<i]).trimmingCharacters(in: .whitespaces)
            buf = String(buf[buf.index(after: i)...])
            guard !line.isEmpty else { continue }
            log += line + "\n"
            if line.hasPrefix("page ") || line.contains("pass ") {
                if line.hasPrefix("page ") { donePages += 1 }
                progress = min(0.98, Double(donePages) / Double(totalUnits))
                status = line.hasPrefix("page ") ? "识别第 \(line.dropFirst(5)) 页…" : line
            }
        }
        if log.count > 4000 { log = String(log.suffix(2000)) }
    }

    private func finish(_ rest: Data, code: Int32) {
        outData.append(rest)
        var s = String(data: outData, encoding: .utf8) ?? ""
        outData = Data()
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        text = s
        running = false
        progress = 1
        let secs = String(format: "%.1f", Date().timeIntervalSince(started))
        if code == 0 && !s.isEmpty {
            status = "完成 · \(s.count) 字 · 用时 \(secs) 秒"
        } else if code == 0 {
            status = "没有识别到文字"
        } else {
            status = "识别失败（退出码 \(code)）"
        }
        proc = nil
    }

    func cancel() {
        proc?.terminate()
        running = false
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "已复制到剪贴板"
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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AppleVisionOCR").font(.system(size: 19, weight: .semibold))
                Text("本地识别 · 不上传").font(.caption).foregroundStyle(.secondary)
            }

            dropZone

            VStack(alignment: .leading, spacing: 10) {
                Text("识别设置").font(.caption).fontWeight(.medium).foregroundStyle(.secondary)

                HStack {
                    Text("页码范围").frame(width: 62, alignment: .leading)
                    TextField("全部", text: $m.pageRange)
                        .textFieldStyle(.roundedBorder)
                        .disabled(m.url?.pathExtension.lowercased() != "pdf")
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

                Toggle("三路投票（更准，约 3 倍耗时）", isOn: $m.vote)
                    .font(.callout)
                Toggle("按 76 字折行", isOn: $m.wrap)
                    .font(.callout)
            }

            if m.running {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: m.progress)
                    Text(m.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Button {
                    m.run()
                } label: {
                    Text("开始识别").frame(maxWidth: .infinity)
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

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 316)
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: m.url == nil ? "arrow.down.doc" : "doc.text.fill")
                .font(.system(size: 26))
                .foregroundStyle(m.url == nil ? Color.secondary : Color.accentColor)
            if let u = m.url {
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
                Text("也可以点击选择").font(.caption).foregroundStyle(.secondary)
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
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                guard let u else { return }
                DispatchQueue.main.async { m.load(u) }
            }
            return true
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
                }
                Button("复制") { m.copyAll() }
                    .disabled(m.text.isEmpty)
                Button("保存…") { m.save() }
                    .disabled(m.text.isEmpty)
                    .keyboardShortcut("s", modifiers: .command)
                if m.running {
                    Button("取消") { m.cancel() }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if m.text.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 38))
                        .foregroundStyle(.tertiary)
                    Text(m.running ? "识别中…" : "结果会显示在这里")
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
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let u = urls.first else { return }
        DispatchQueue.main.async { OCRModel.shared?.load(u) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum SelfTest {
    static func runModel(path: String) {
        _ = NSApplication.shared
        let m = OCRModel()
        m.load(URL(fileURLWithPath: path))
        m.vote = false
        if let pg = ProcessInfo.processInfo.environment["OCRPAGES"] {
            m.pageRange = pg
            m.vote = true
        }
        m.run()
        let deadline = Date().addingTimeInterval(180)
        while m.running && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        print("status: \(m.status)")
        print("chars: \(m.text.count)")
        print("progress: \(m.progress)")
        print("head: \(m.text.prefix(60).replacingOccurrences(of: "\n", with: " | "))")
    }

    static func snapshot(to path: String) {
        _ = NSApplication.shared
        let m = OCRModel()
        m.url = URL(fileURLWithPath: "/Users/macos/Downloads/书籍资料/钱从哪里来7 (香帅) (z-library.sk, 1lib.sk, z-lib.sk).pdf")
        m.pageCount = 258
        m.status = "已载入 钱从哪里来7：重置.pdf · 258 页"
        if ProcessInfo.processInfo.environment["OCRSNAP"] == "run" {
            m.running = true
            m.progress = 0.42
            m.status = "识别第 108 页…"
        }
        if ProcessInfo.processInfo.environment["OCRSNAP"] == "empty" {
            m.url = nil
            m.pageCount = 0
            m.status = "把 PDF 或图片拖进来"
        }
        m.text = """
        《钱从哪里来7：重置》　香帅 著　新星出版社
        收录：前言、第一章至第五章（原书第001—124页）

        ==========================================================
        第一章　资金的岛链化叙事
        ==========================================================

        岛链化叙事

        “美国制造业回来了！”
        2022年12月，在亚利桑那州凤凰城郊外沙漠的一个工厂里，时任美国总统的拜登（Biden）发出了这个激动的声音——台积电投资建设的晶圆厂正在举行盛大的首批设备搬入仪式。
        """
        let v = NSHostingView(rootView: ContentView(m: m))
        v.frame = CGRect(x: 0, y: 0, width: 960, height: 660)
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { print("no rep"); return }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let d = rep.representation(using: .png, properties: [:]) {
            try? d.write(to: URL(fileURLWithPath: path))
            print("saved \(path)")
        }
    }

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
