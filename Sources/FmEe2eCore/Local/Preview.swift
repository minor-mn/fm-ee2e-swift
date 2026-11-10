import AppKit
import QuickLookThumbnailing

/// プレビューできるファイルの種類。
nonisolated enum PreviewKind: Sendable {
  case image
  case video

  /// Markdown（ローカルだけ）。画像にせず、文字として描く。
  case markdown
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

/// Markdown のファイルの名前か（.md・.markdown）。[previewKindOf] は画像・動画だけなので、別に見る。
nonisolated func isMarkdownName(_ name: String) -> Bool {
  let ext = p.extension(name).lowercased()
  return ext == ".md" || ext == ".markdown"
}

/// プレビューの長い辺の上限（ピクセル）。大きな写真を覚えておかないよう、これより大きければ縮める。
private let previewSize = 1600

/// [path] のプレビューの画像。動画は Quick Look のサムネイル（先頭付近の1コマ）。作れなければ nil。
func makePreview(_ path: String, _ kind: PreviewKind) async -> NSImage? {
  switch kind {
  case .image:
    return NSImage(contentsOfFile: path).flatMap { shrink($0, previewSize) }
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
  case .markdown:
    // Markdown は画像にせず、[PreviewOverlay] が文字として描く。
    return nil
  }
}

/// 画像のデータ [data] のプレビュー（SSH の接続先から読んだもの）。読めなければ nil。
func makePreview(_ data: Data) -> NSImage? {
  NSImage(data: data).flatMap { shrink($0, previewSize) }
}

/// タイル表示のサムネイルの長い辺の上限（ピクセル）。
private let thumbnailSize = 400

/// [path] の画像・動画のタイル表示のサムネイル（Quick Look）。作れなければ nil。
func makeThumbnail(_ path: String) async -> NSImage? {
  let request = QLThumbnailGenerator.Request(
    fileAt: URL(fileURLWithPath: path),
    size: CGSize(width: thumbnailSize, height: thumbnailSize),
    scale: 1,
    representationTypes: .thumbnail
  )
  if let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
    return thumbnail.nsImage
  }
  return NSImage(contentsOfFile: path).flatMap { shrink($0, thumbnailSize) }
}

/// 画像のデータ [data] のタイル表示のサムネイル（SSH の接続先から読んだもの）。読めなければ nil。
func makeThumbnail(_ data: Data) -> NSImage? {
  NSImage(data: data).flatMap { shrink($0, thumbnailSize) }
}

/// [image] の長い辺が [limit] を超えていれば縮める。大きさが分からなければ nil。
private func shrink(_ image: NSImage, _ limit: Int) -> NSImage? {
  let pixels = image.representations.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }.max { $0.width < $1.width }
  guard let pixels, pixels.width > 0, pixels.height > 0 else {
    return nil
  }
  let scale = min(1, Double(limit) / max(pixels.width, pixels.height))
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
