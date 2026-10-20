// make-showcase — 生成 README 用的「截图 → 文本」对比图
//
// 用法: make-showcase <输入图片> <文本文件> <输出png>
//
// 左：原始截图；右：OCR 结果（CoreText 自动排版）。

import AppKit
import CoreGraphics
import CoreText
import ImageIO

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: make-showcase <image> <text> <out.png>\n".data(using: .utf8)!)
    exit(1)
}

let imageURL = URL(fileURLWithPath: args[1])
let textURL = URL(fileURLWithPath: args[2])
let outURL = URL(fileURLWithPath: args[3])

guard let src = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
      let shot = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write("cannot read image\n".data(using: .utf8)!)
    exit(1)
}
let body = (try? String(contentsOf: textURL, encoding: .utf8)) ?? ""

// 画布
let W = 1660, H = 812
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// 背景
ctx.setFillColor(color(245, 246, 248))
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

// ---- 左侧：截图 ----
let pad: CGFloat = 56
let imgW: CGFloat = 700
let imgH = imgW * CGFloat(shot.height) / CGFloat(shot.width)
let imgRect = CGRect(x: pad, y: (CGFloat(H) - imgH) / 2, width: imgW, height: imgH)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 24,
              color: color(15, 23, 42, 0.16))
let card = CGPath(roundedRect: imgRect.insetBy(dx: -6, dy: -6), cornerWidth: 16, cornerHeight: 16, transform: nil)
ctx.setFillColor(color(255, 255, 255))
ctx.addPath(card)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(CGPath(roundedRect: imgRect, cornerWidth: 12, cornerHeight: 12, transform: nil))
ctx.clip()
ctx.draw(shot, in: imgRect)
ctx.restoreGState()

// ---- 右侧：文本面板 ----
let panelX = pad + imgW + 92
let panelW = CGFloat(W) - panelX - pad
let panelRect = CGRect(x: panelX, y: 92, width: panelW, height: CGFloat(H) - 184)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: color(15, 23, 42, 0.18))
ctx.setFillColor(color(28, 31, 36))
ctx.addPath(CGPath(roundedRect: panelRect, cornerWidth: 16, cornerHeight: 16, transform: nil))
ctx.fillPath()
ctx.restoreGState()

// 面板顶部三个小圆点，暗示"文本窗口"
for i in 0..<3 {
    let dot = CGRect(x: panelRect.minX + 26 + CGFloat(i) * 20, y: panelRect.maxY - 30, width: 10, height: 10)
    ctx.setFillColor(color(255, 255, 255, 0.22))
    ctx.fillEllipse(in: dot)
}

// 正文
let style = NSMutableParagraphStyle()
style.lineSpacing = 7.5
style.paragraphSpacing = 6
let attr = NSAttributedString(string: body, attributes: [
    .font: NSFont(name: "PingFangSC-Regular", size: 14.5) ?? NSFont.systemFont(ofSize: 15),
    .foregroundColor: NSColor(calibratedRed: 0.91, green: 0.92, blue: 0.94, alpha: 1),
    .paragraphStyle: style,
])

let textRect = CGRect(x: panelRect.minX + 32, y: panelRect.minY + 28,
                      width: panelRect.width - 64, height: panelRect.height - 100)
let framesetter = CTFramesetterCreateWithAttributedString(attr)
let path = CGPath(rect: textRect, transform: nil)
let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
ctx.saveGState()
ctx.textMatrix = .identity
CTFrameDraw(frame, ctx)
ctx.restoreGState()

// 中间箭头
let arrowY = CGFloat(H) / 2
ctx.setStrokeColor(color(120, 130, 145, 0.85))
ctx.setLineWidth(2.4)
ctx.setLineCap(.round)
let ax = imgRect.maxX + 26, bx = panelX - 26
ctx.move(to: CGPoint(x: ax, y: arrowY))
ctx.addLine(to: CGPoint(x: bx - 12, y: arrowY))
ctx.strokePath()
ctx.move(to: CGPoint(x: bx - 22, y: arrowY + 9))
ctx.addLine(to: CGPoint(x: bx - 10, y: arrowY))
ctx.addLine(to: CGPoint(x: bx - 22, y: arrowY - 9))
ctx.strokePath()

// 顶部标签
func label(_ text: String, x: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(calibratedRed: 0.45, green: 0.48, blue: 0.53, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    ctx.textPosition = CGPoint(x: x, y: CGFloat(H) - 46)
    CTLineDraw(line, ctx)
}
label("输入 · 截图", x: imgRect.minX)
label("输出 · 文本", x: panelRect.minX + 32)

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: outURL)
print("saved \(outURL.path)")
