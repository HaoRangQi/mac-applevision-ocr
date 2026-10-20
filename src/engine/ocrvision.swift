// ocrvision — macOS 原生 Vision OCR 引擎
// 输入 PDF 或图片，输出逐行 JSON（含坐标），供上层做投票与排版。
//
// 用法: ocrvision --input FILE [--pages A-B] [--scale 4.5] [--rot 0] [--lang zh-Hans,en-US]
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
        case "--help", "-h":
            FileHandle.standardError.write("""
            ocrvision --input FILE [--pages A-B] [--scale 4.5] [--rot 0] [--lang zh-Hans,en-US] [--no-correct] [--fast]

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

let ext = url.pathExtension.lowercased()
let isPDF = ext == "pdf"

if isPDF {
    guard let doc = PDFDocument(url: url) else {
        FileHandle.standardError.write("error: cannot open pdf\n".data(using: .utf8)!)
        exit(2)
    }
    var start = 1, end = doc.pageCount
    if opt.pages != "all" {
        let parts = opt.pages.split(separator: "-").map { Int($0) ?? 0 }
        if parts.count == 2 { start = max(1, parts[0]); end = min(doc.pageCount, parts[1]) }
        else if parts.count == 1 { start = max(1, parts[0]); end = start }
    }
    for i in (start - 1)..<end {
        guard let page = doc.page(at: i), let img = renderPDFPage(page) else { continue }
        emit(page: i + 1, lines: ocr(img))
        FileHandle.standardError.write("page \(i + 1)\n".data(using: .utf8)!)
    }
} else {
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
    FileHandle.standardError.write("image done\n".data(using: .utf8)!)
}
