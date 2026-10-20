// make-test-pdf — 生成一个 4 页测试 PDF，每页印上页码。
// 用途：CI 里验证 `--pages` 的解析结果是否正确选中页面。
// 用法: make-test-pdf <输出路径>

import AppKit
import CoreGraphics
import CoreText
import Foundation

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: make-test-pdf <out.pdf>\n".data(using: .utf8)!)
    exit(1)
}

let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
let pages = 4
var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 300)

let data = NSMutableData()
guard let consumer = CGDataConsumer(data: data),
      let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
    FileHandle.standardError.write("cannot create pdf\n".data(using: .utf8)!)
    exit(1)
}

for i in 1...pages {
    ctx.beginPage(mediaBox: &mediaBox)
    let text = NSAttributedString(string: "PAGE \(i)", attributes: [
        .font: NSFont.systemFont(ofSize: 64, weight: .bold),
        .foregroundColor: NSColor.black,
    ])
    let line = CTLineCreateWithAttributedString(text)
    ctx.textPosition = CGPoint(x: 60, y: 110)
    CTLineDraw(line, ctx)
    ctx.endPage()
}
ctx.closePDF()

if !data.write(to: outURL, atomically: true) {
    FileHandle.standardError.write("cannot write pdf\n".data(using: .utf8)!)
    exit(1)
}
print("wrote \(outURL.path) (\(pages) pages)")
