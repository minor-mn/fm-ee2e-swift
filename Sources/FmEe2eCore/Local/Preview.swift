import AppKit
import QuickLookThumbnailing

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

/// プレビューの長い辺の上限（ピクセル）。大きな写真を覚えておかないよう、これより大きければ縮める。
private let previewSize = 1600

/// [path] のプレビューの画像。動画は Quick Look のサムネイル（先頭付近の1コマ）。作れなければ nil。
func makePreview(_ path: String, _ kind: PreviewKind) async -> NSImage? {
  switch kind {
  case .image:
    return NSImage(contentsOfFile: path).flatMap(shrink)
  case .video:
    let request = QLThumbnailGenerator.Request(
      fileAt: URL(fileURLWithPath: path),
      size: CGSize(width: previewSize, height: previewSize),
      scale: 1,
      representationTypes: .thumbnail
    )
    guard let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
      return nil
    }
    return thumbnail.nsImage
  }
}

/// 画像のデータ [data] のプレビュー（SSH の接続先から読んだもの）。読めなければ nil。
func makePreview(_ data: Data) -> NSImage? {
  NSImage(data: data).flatMap(shrink)
}

/// [image] の長い辺が [previewSize] を超えていれば縮める。大きさが分からなければ nil。
private func shrink(_ image: NSImage) -> NSImage? {
  let pixels = image.representations.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }.max { $0.width < $1.width }
  guard let pixels, pixels.width > 0, pixels.height > 0 else {
    return nil
  }
  let scale = min(1, Double(previewSize) / max(pixels.width, pixels.height))
  if scale == 1 {
    return image
  }
  let width = Int((pixels.width * scale).rounded())
  let height = Int((pixels.height * scale).rounded())
  guard
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )
  else {
    return nil
  }
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  NSGraphicsContext.current?.imageInterpolation = .high
  image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
  NSGraphicsContext.restoreGraphicsState()
  let shrunk = NSImage(size: NSSize(width: width, height: height))
  shrunk.addRepresentation(bitmap)
  return shrunk
}
