// make-fixture-pdf — 把 PNG 包成单页 PDF，用作界面截图与测试用的 PDF 素材。
// 用途：让「多路投票」这类仅 PDF 生效的功能在截图里能真实展示。
// 用法: make-fixture-pdf <in.png> <out.pdf>

import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write("usage: make-fixture-pdf <in.png> <out.pdf>\n".data(using: .utf8)!)
    exit(1)
}

let inPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
guard let img = NSImage(contentsOfFile: inPath),
      let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let cg = rep.cgImage else {
    FileHandle.standardError.write("cannot load image\n".data(using: .utf8)!)
    exit(1)
}

var mediaBox = CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height))
let data = NSMutableData()
guard let consumer = CGDataConsumer(data: data),
      let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
    FileHandle.standardError.write("cannot create pdf\n".data(using: .utf8)!)
    exit(1)
}
ctx.beginPage(mediaBox: &mediaBox)
ctx.draw(cg, in: mediaBox)
ctx.endPage()
ctx.closePDF()

try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(cg.width)x\(cg.height))")
