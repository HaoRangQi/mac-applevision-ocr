import AppKit
import CoreGraphics

let S = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let f = CGFloat(S)

// 背景：圆角矩形 + 蓝青渐变
let rect = CGRect(x: 0, y: 0, width: f, height: f).insetBy(dx: f * 0.055, dy: f * 0.055)
let path = CGPath(roundedRect: rect, cornerWidth: f * 0.225, cornerHeight: f * 0.225, transform: nil)
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let grad = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.13, green: 0.42, blue: 0.93, alpha: 1),
    CGColor(red: 0.09, green: 0.72, blue: 0.79, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: f), end: CGPoint(x: f, y: 0), options: [])
ctx.restoreGState()

// 纸张
let paper = CGRect(x: f * 0.245, y: f * 0.215, width: f * 0.51, height: f * 0.60)
let pPath = CGPath(roundedRect: paper, cornerWidth: f * 0.045, cornerHeight: f * 0.045, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -f * 0.018), blur: f * 0.05,
              color: CGColor(red: 0, green: 0.12, blue: 0.3, alpha: 0.28))
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.98))
ctx.addPath(pPath)
ctx.fillPath()
ctx.restoreGState()

// 纸上的文字行
ctx.setFillColor(CGColor(red: 0.35, green: 0.45, blue: 0.58, alpha: 1))
let widths: [CGFloat] = [0.33, 0.39, 0.28, 0.36, 0.22]
for (i, w) in widths.enumerated() {
    let y = paper.maxY - f * 0.115 - CGFloat(i) * f * 0.083
    let r = CGRect(x: paper.minX + f * 0.075, y: y, width: f * w, height: f * 0.030)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: f * 0.015, cornerHeight: f * 0.015, transform: nil))
    ctx.fillPath()
}

// 扫描光带
ctx.saveGState()
ctx.setBlendMode(.normal)
let bandY = paper.minY + f * 0.175
let band = CGRect(x: paper.minX - f * 0.02, y: bandY, width: paper.width + f * 0.04, height: f * 0.062)
ctx.setFillColor(CGColor(red: 0.11, green: 0.80, blue: 0.85, alpha: 0.30))
ctx.fill(band)
ctx.setFillColor(CGColor(red: 0.11, green: 0.88, blue: 0.90, alpha: 1))
ctx.fill(CGRect(x: band.minX, y: bandY + f * 0.026, width: band.width, height: f * 0.010))
ctx.restoreGState()

let img = ctx.makeImage()!
let dest = URL(fileURLWithPath: "icon_1024.png")
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: dest)
print("ok")
