// ocrvision — macOS 原生 Vision OCR 引擎
// 输入 PDF 或图片，输出逐行 JSON（含坐标），供上层做投票与排版。
//
// 用法: ocrvision --input FILE [--pages A-B | 1,3-5] [--scale 4.5] [--rot 0] [--lang zh-Hans,en-US] [-q]
//       ocrvision --input FILE --count        只打印页数（PDF 有效，图片为 1）
// 进度: 每处理一页往 stderr 写一行「page N」（-q 关闭），上层据此做实时进度
// 输出: 每行一个 JSON: {"p":页码,"x":0-1,"y":0-1,"w":..,"h":..,"t":"文本"}

import Foundation
import PDFKit
import Vision
import CoreGraphics
import CoreImage
import ImageIO
import AppKit

struct Options {
    var input = ""
    var pages = "all"
    var scale = 4.5
    var rot = 0.0
    var langs = ["zh-Hans", "en-US"]
    var correct = true
    var fast = false
    var count = false
    var quiet = false
}

func parseArgs() -> Options {
    var o = Options()
    var a = CommandLine.arguments.dropFirst().makeIterator()
    while let k = a.next() {
        switch k {
        case "--input", "-i": o.input = a.next() ?? ""
        case "--pages", "-p": o.pages = a.next() ?? "all"
        case "--scale", "-s": o.scale = Double(a.next() ?? "4.5") ?? 4.5
        case "--rot", "-r": o.rot = Double(a.next() ?? "0") ?? 0
        case "--lang", "-l": o.langs = (a.next() ?? "zh-Hans,en-US").split(separator: ",").map(String.init)
        case "--no-correct": o.correct = false
        case "--fast": o.fast = true
        case "--count": o.count = true
        case "--quiet", "-q": o.quiet = true
        case "--help", "-h":
            FileHandle.standardError.write("""
            ocrvision --input FILE [--pages A-B | 1,3-5] [--scale 4.5] [--rot 0] [--lang zh-Hans,en-US] [--no-correct] [--fast]
            ocrvision --input FILE --count        只打印页数（PDF 有效，图片为 1）

            """.data(using: .utf8)!)
            exit(0)
        default:
            if o.input.isEmpty { o.input = k }
        }
    }
    return o
}

func esc(_ s: String) -> String {
    var o = ""
    for u in s.unicodeScalars {
        switch u {
        case "\"": o += "\\\""
        case "\\": o += "\\\\"
        case "\n": o += "\\n"
        case "\r": o += "\\r"
        case "\t": o += "\\t"
        default:
            if u.value < 0x20 { o += " " } else { o.unicodeScalars.append(u) }
        }
    }
    return o
}

let opt = parseArgs()
if opt.input.isEmpty {
    FileHandle.standardError.write("error: --input required\n".data(using: .utf8)!)
    exit(2)
}

let url = URL(fileURLWithPath: (opt.input as NSString).expandingTildeInPath)
guard FileManager.default.fileExists(atPath: url.path) else {
    FileHandle.standardError.write("error: file not found: \(url.path)\n".data(using: .utf8)!)
    exit(2)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = opt.fast ? .fast : .accurate
request.usesLanguageCorrection = opt.correct
request.recognitionLanguages = opt.langs
if #available(macOS 13.0, *) {
    request.revision = VNRecognizeTextRequestRevision3
}

/// 对一张 CGImage 做 OCR，返回 (x, y, w, h, text)；坐标归一化到 0-1，y 从上往下
func ocr(_ img: CGImage) -> [(Double, Double, Double, Double, String)] {
    var cg = img
    if opt.rot != 0 {
        let ci = CIImage(cgImage: cg).transformed(by: CGAffineTransform(rotationAngle: CGFloat(opt.rot * Double.pi / 180)))
        if let out = CIContext().createCGImage(ci, from: ci.extent) { cg = out }
    }
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    do { try handler.perform([request]) } catch { return [] }
    guard let obs = request.results else { return [] }
    let sorted = obs.sorted { a, b in
        if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.006 { return a.boundingBox.midY > b.boundingBox.midY }
        return a.boundingBox.minX < b.boundingBox.minX
    }
    var out: [(Double, Double, Double, Double, String)] = []
    for o in sorted {
        guard let c = o.topCandidates(1).first else { continue }
        let t = c.string.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { continue }
        let bb = o.boundingBox
        out.append((Double(bb.minX), Double(1.0 - bb.maxY), Double(bb.width), Double(bb.height), t))
    }
    return out
}

func emit(page: Int, lines: [(Double, Double, Double, Double, String)]) {
    var buf = ""
    for (x, y, w, h, t) in lines {
        buf += "{\"p\":\(page),\"x\":\(String(format: "%.4f", x)),\"y\":\(String(format: "%.4f", y)),"
        buf += "\"w\":\(String(format: "%.4f", w)),\"h\":\(String(format: "%.4f", h)),\"t\":\"\(esc(t))\"}\n"
    }
    FileHandle.standardOutput.write(buf.data(using: .utf8)!)
}

func renderPDFPage(_ page: PDFPage) -> CGImage? {
    let r = page.bounds(for: .mediaBox)
    let w = Int(r.width * opt.scale), h = Int(r.height * opt.scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: opt.scale, y: opt.scale)
    page.draw(with: .mediaBox, to: ctx)
    return ctx.makeImage()
}

// 把页码规格解析成升序去重的 1-based 页码数组。
// 语法：`all` 或空 = 全部；逗号分隔多段；每段为单个页码 `A` 或区间 `A-B`。
// 负数从末尾数：`-10` = 最后 10 页；`10--3` = 第 10 页到倒数第 3 页。
// 倒序区间自动纠正，越界页号裁掉，重复页号合并。非法写法报错退出。
func resolvePages(_ spec: String, total: Int) -> [Int] {
    let s = spec.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty || s.lowercased() == "all" || total <= 0 {
        return Array(1...max(total, 0))
    }
    func fromEnd(_ n: Int) -> Int { n > 0 ? n : total + 1 + n }   // -1 → 最后一页

    let rangeRe = try! NSRegularExpression(pattern: #"^(-?\d+)\s*-\s*(-?\d+)$"#)
    let singleRe = try! NSRegularExpression(pattern: #"^(-?\d+)$"#)

    func readGroups(_ re: NSRegularExpression, _ text: String) -> [Int]? {
        let full = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: full) else { return nil }
        var out: [Int] = []
        for i in 1..<m.numberOfRanges {
            guard let r = Range(m.range(at: i), in: text) else { return nil }
            out.append(Int(text[r]) ?? Int.min)
        }
        return out.isEmpty ? nil : out
    }

    var picked = Set<Int>()
    for raw in s.split(separator: ",", omittingEmptySubsequences: false) {
        let token = String(raw).trimmingCharacters(in: .whitespaces)
        if token.isEmpty { continue }
        if let rg = readGroups(rangeRe, token), rg.count == 2 {
            let a = fromEnd(rg[0]), b = fromEnd(rg[1])
            let lo = min(a, b), hi = max(a, b)                 // 倒序区间自动纠正
            for p in lo...hi where p >= 1 && p <= total { picked.insert(p) }
        } else if let one = readGroups(singleRe, token), let n = one.first {
            if n > 0 {
                if n >= 1 && n <= total { picked.insert(n) }   // 越界页号直接忽略
            } else {                                           // -N = 最后 N 页
                for p in (total + 1 + n)...total where p >= 1 { picked.insert(p) }
            }
        } else {
            FileHandle.standardError.write(
                "error: invalid page token '\(token)' in '\(s)'\n".data(using: .utf8)!)
            exit(3)
        }
    }
    return picked.sorted()
}

// 进度日志：每处理一页往 stderr 写一行「page N」。
// 上层（Python CLI / 图形界面）靠这个做实时进度，所以不要缓冲、不要省略。
func progress(_ page: Int) {
    if !opt.quiet {
        FileHandle.standardError.write("page \(page)\n".data(using: .utf8)!)
    }
}

let ext = url.pathExtension.lowercased()
let isPDF = ext == "pdf"

if isPDF {
    guard let doc = PDFDocument(url: url) else {
        FileHandle.standardError.write("error: cannot open pdf\n".data(using: .utf8)!)
        exit(2)
    }
    if opt.count {
        print(doc.pageCount)
        exit(0)
    }
    for pageNo in resolvePages(opt.pages, total: doc.pageCount) {
        guard let page = doc.page(at: pageNo - 1), let img = renderPDFPage(page) else { continue }
        progress(pageNo)
        emit(page: pageNo, lines: ocr(img))
    }
} else {
    if opt.count {
        print(1)
        exit(0)
    }
    progress(1)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        FileHandle.standardError.write("error: cannot read image\n".data(using: .utf8)!)
        exit(2)
    }
    // 小图放大到长边约 2000px，提升识别率
    var use = img
    let longSide = max(img.width, img.height)
    if longSide < 1600 {
        let f = 2000.0 / Double(longSide)
        let w = Int(Double(img.width) * f), h = Int(Double(img.height) * f)
        if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let scaled = ctx.makeImage() { use = scaled }
        }
    }
    emit(page: 1, lines: ocr(use))
    if !opt.quiet {
        FileHandle.standardError.write("image done\n".data(using: .utf8)!)
    }
}
