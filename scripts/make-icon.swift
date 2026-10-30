// アプリのアイコン（1024×1024 の PNG）を描く。使い方: swift scripts/make-icon.swift <出力先.png>
// 左右2つの窓と、右の窓の鍵（暗号化）を、アプリの配色で描く。
import AppKit

let size = 1024.0
let output = CommandLine.arguments[1]

func color(_ hex: Int, _ alpha: Double = 1) -> CGColor {
  CGColor(
    srgbRed: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255,
    alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
  data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS のアイコンの形（角の丸い四角。周りに余白を空ける）。
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)

// 影。
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.45))
context.addPath(platePath)
context.setFillColor(color(0x12161D))
context.fillPath()
context.restoreGState()

// 地のグラデーション（窓の背景と同じ色）。
context.saveGState()
context.addPath(platePath)
context.clip()
let gradient = CGGradient(colorsSpace: space, colors: [color(0x2A1650), color(0x0B2A2A)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: plate.minX, y: plate.maxY), end: CGPoint(x: plate.maxX, y: plate.minY), options: [])

// 上の帯。
let header = CGRect(x: 170, y: 760, width: 684, height: 70)
context.addPath(CGPath(roundedRect: header, cornerWidth: 18, cornerHeight: 18, transform: nil))
context.setFillColor(color(0x000000, 0.55))
context.fillPath()
context.setFillColor(color(0x9B6BFF))
context.fill(CGRect(x: 200, y: 785, width: 150, height: 20))

// 左右の窓。
func pane(_ frame: CGRect, _ border: Int, _ fill: Int) {
  let path = CGPath(roundedRect: frame, cornerWidth: 22, cornerHeight: 22, transform: nil)
  context.addPath(path)
  context.setFillColor(color(fill, 0.75))
  context.fillPath()
  context.addPath(path)
  context.setStrokeColor(color(border))
  context.setLineWidth(10)
  context.strokePath()
}
let left = CGRect(x: 170, y: 250, width: 330, height: 480)
let right = CGRect(x: 524, y: 250, width: 330, height: 480)
pane(left, 0x9B6BFF, 0x1A1530)
pane(right, 0x5CD8FF, 0x0F2530)

// 左の窓のファイルの行（1行目はカーソル）。
context.setFillColor(color(0x3A2A6E))
context.fill(CGRect(x: 182, y: 652, width: 306, height: 46))
for i in 0..<6 {
  let y = 664 - Double(i) * 62
  context.setFillColor(color(i < 2 ? 0x9B6BFF : 0xE6E6E6, i == 0 ? 1 : 0.8))
  context.fill(CGRect(x: 205, y: y, width: [190, 150, 220, 170, 200, 130][i], height: 22))
}

// 右の窓の鍵（暗号化）。
let lockBody = CGRect(x: 609, y: 340, width: 160, height: 130)
context.addPath(CGPath(roundedRect: lockBody, cornerWidth: 22, cornerHeight: 22, transform: nil))
context.setFillColor(color(0x5CD8FF))
context.fillPath()
context.setStrokeColor(color(0x5CD8FF))
context.setLineWidth(26)
context.setLineCap(.butt)
context.addArc(center: CGPoint(x: 689, y: 500), radius: 52, startAngle: 0, endAngle: .pi, clockwise: false)
context.addLine(to: CGPoint(x: 637, y: 470))
context.move(to: CGPoint(x: 741, y: 500))
context.addLine(to: CGPoint(x: 741, y: 470))
context.strokePath()
context.setFillColor(color(0x0F2530))
context.fillEllipse(in: CGRect(x: 671, y: 405, width: 36, height: 36))
context.fill(CGRect(x: 681, y: 368, width: 16, height: 45))

// 下のファンクションキーの帯。
for i in 0..<4 {
  let x = 170 + Double(i) * 177
  context.addPath(CGPath(roundedRect: CGRect(x: x, y: 165, width: 155, height: 46), cornerWidth: 10, cornerHeight: 10, transform: nil))
  context.setFillColor(color(0xE3F86A))
  context.fillPath()
}
context.restoreGState()

let image = context.makeImage()!
let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: output))
