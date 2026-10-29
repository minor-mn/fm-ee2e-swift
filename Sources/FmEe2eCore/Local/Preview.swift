import Foundation

/// プレビューできるファイルの種類。
nonisolated enum PreviewKind: Sendable {
  case image
  case video
}

private nonisolated let imageExtensions: Set<String> = [
  ".jpg", ".jpeg", ".png", ".gif", ".heic", ".heif", ".webp", ".tif", ".tiff", ".bmp",
]
private nonisolated let videoExtensions: Set<String> = [".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm", ".3gp"]

/// 名前（拡張子）から、プレビューできる種類を返す。できなければ nil。
nonisolated func previewKindOf(_ name: String) -> PreviewKind? {
  let ext = p.extension(name).lowercased()
  if imageExtensions.contains(ext) {
    return .image
  }
  if videoExtensions.contains(ext) {
    return .video
  }
  return nil
}

/// iTerm2 の画像表示（OSC 1337）が使える端末か。ssh 越しでも LC_TERMINAL が渡る。
nonisolated var canShowImages: Bool {
  let env = ProcessInfo.processInfo.environment
  return env["TERM_PROGRAM"] == "iTerm.app" || env["LC_TERMINAL"] == "iTerm2"
}

/// [path] を長い辺 [size] ピクセル以下の JPEG にして返す。動画は Quick Look のサムネイル（先頭付近の1コマ）。
/// [work] は作業用の空のフォルダー。作れなければ nil。
func makePreview(_ path: String, _ kind: PreviewKind, _ work: String, size: Int = 800) async -> Data? {
  await convert(path, kind, work, size, ["-s", "format", "jpeg", "-s", "formatOptions", "80"], "jpg")
}

/// [path] を長い辺 [size] ピクセル以下に縮めた画素にして返す（端末の文字で描く用）。作れなければ nil。
func makePreviewPixels(_ path: String, _ kind: PreviewKind, _ work: String, size: Int = 320) async -> PreviewPixels? {
  guard let bytes = await convert(path, kind, work, size, ["-s", "format", "bmp"], "bmp") else {
    return nil
  }
  return parseBmp(bytes)
}

private func convert(
  _ path: String,
  _ kind: PreviewKind,
  _ work: String,
  _ size: Int,
  _ format: [String],
  _ extension: String
) async -> Data? {
  var source = path
  if kind == .video {
    let result = try? await runProcess("/usr/bin/qlmanage", ["-t", "-s", "\(size)", "-o", work, path])
    let thumbnail = p.join(work, "\(p.basename(path)).png")
    guard let result, result.exitCode == 0, FileManager.default.fileExists(atPath: thumbnail) else {
      return nil
    }
    source = thumbnail
  }
  let out = p.join(work, "preview.\(`extension`)")
  let result = try? await runProcess("/usr/bin/sips", ["-Z", "\(size)"] + format + [source, "--out", out])
  guard let result, result.exitCode == 0, FileManager.default.fileExists(atPath: out) else {
    return nil
  }
  return FileManager.default.contents(atPath: out)
}

/// 画素（RGB を3バイトずつ、左上から行ごと）。
nonisolated final class PreviewPixels: Sendable {
  init(_ width: Int, _ height: Int, _ rgb: [UInt8]) {
    self.width = width
    self.height = height
    self.rgb = rgb
  }

  let width: Int
  let height: Int
  let rgb: [UInt8]

  /// 縦横比を保ったまま [maxWidth]×[maxHeight] に収まるよう、平均を取って縮める（広げはしない）。
  func fit(_ maxWidth: Int, _ maxHeight: Int) -> PreviewPixels {
    let scale = min(Double(maxWidth) / Double(width), Double(maxHeight) / Double(height), 1.0)
    let w = min(max(Int((Double(width) * scale).rounded()), 1), width)
    let h = min(max(Int((Double(height) * scale).rounded()), 1), height)
    if w == width && h == height {
      return self
    }
    var out = [UInt8](repeating: 0, count: w * h * 3)
    for y in 0..<h {
      let y0 = y * height / h
      let y1 = min(max((y + 1) * height / h, y0 + 1), height)
      for x in 0..<w {
        let x0 = x * width / w
        let x1 = min(max((x + 1) * width / w, x0 + 1), width)
        var r = 0
        var g = 0
        var b = 0
        for sy in y0..<y1 {
          for sx in x0..<x1 {
            let i = (sy * width + sx) * 3
            r += Int(rgb[i])
            g += Int(rgb[i + 1])
            b += Int(rgb[i + 2])
          }
        }
        let n = (y1 - y0) * (x1 - x0)
        let o = (y * w + x) * 3
        out[o] = UInt8(r / n)
        out[o + 1] = UInt8(g / n)
        out[o + 2] = UInt8(b / n)
      }
    }
    return PreviewPixels(w, h, out)
  }

  /// (x, y) の色（0xRRGGBB）。
  func at(_ x: Int, _ y: Int) -> Int {
    let i = (y * width + x) * 3
    return (Int(rgb[i]) << 16) | (Int(rgb[i + 1]) << 8) | Int(rgb[i + 2])
  }
}

/// sips が出す BMP（24 ビット、または色の位置を指定した 32 ビット）を読む。透明な部分は [background] と混ぜる。
nonisolated func parseBmp(_ data: Data, background: Int = 0x12161D) -> PreviewPixels? {
  let bytes = [UInt8](data)
  if bytes.count < 54 || bytes[0] != 0x42 || bytes[1] != 0x4D {
    return nil
  }
  // 足りなければ読めない BMP とする。
  func u32(_ at: Int) -> Int? {
    guard at + 4 <= bytes.count else { return nil }
    return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
  }
  func i32(_ at: Int) -> Int? { u32(at).map { Int(Int32(truncatingIfNeeded: $0)) } }
  let offset = u32(10)!
  let headerSize = u32(14)!
  let width = i32(18)!
  let rawHeight = i32(22)!
  let bpp = Int(bytes[28]) | Int(bytes[29]) << 8
  let compression = u32(30)!
  let height = abs(rawHeight)
  if width <= 0 || height == 0 || (bpp != 24 && bpp != 32) || (compression != 0 && compression != 3) {
    return nil
  }
  // 32 ビットの既定は BGRA。色の位置の指定（BI_BITFIELDS）があればそれに従う。
  var masks = [0x00FF_0000, 0x0000_FF00, 0x0000_00FF, bpp == 32 ? 0xFF00_0000 : 0]
  if compression == 3 {
    guard let r = u32(54), let g = u32(58), let b = u32(62) else {
      return nil
    }
    // 透明度の位置は V3 以降のヘッダーにだけある。
    var a = 0
    if headerSize >= 56 {
      guard let value = u32(66) else {
        return nil
      }
      a = value
    }
    masks = [r, g, b, a]
  }
  func channel(_ value: Int, _ mask: Int) -> Int {
    if mask == 0 {
      return 255
    }
    var shift = 0
    while (mask >> shift) & 1 == 0 {
      shift += 1
    }
    let max = mask >> shift
    return ((value & mask) >> shift) * 255 / max
  }

  let stride = (width * bpp / 8 + 3) & ~3
  if offset + stride * height > bytes.count {
    return nil
  }
  var rgb = [UInt8](repeating: 0, count: width * height * 3)
  let bgR = (background >> 16) & 0xff
  let bgG = (background >> 8) & 0xff
  let bgB = background & 0xff
  for y in 0..<height {
    // 高さが正なら下の行から並んでいる。
    let row = offset + (rawHeight > 0 ? height - 1 - y : y) * stride
    for x in 0..<width {
      let value: Int
      if bpp == 32 {
        let i = row + x * 4
        value = Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
      } else {
        let i = row + x * 3
        value = Int(bytes[i]) | (Int(bytes[i + 1]) << 8) | (Int(bytes[i + 2]) << 16)
      }
      let a = channel(value, masks[3])
      let o = (y * width + x) * 3
      rgb[o] = UInt8((channel(value, masks[0]) * a + bgR * (255 - a)) / 255)
      rgb[o + 1] = UInt8((channel(value, masks[1]) * a + bgG * (255 - a)) / 255)
      rgb[o + 2] = UInt8((channel(value, masks[2]) * a + bgB * (255 - a)) / 255)
    }
  }
  return PreviewPixels(width, height, rgb)
}
