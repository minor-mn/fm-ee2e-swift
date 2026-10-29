import Foundation

/// 画像・動画のプレビューの描き方。
enum PreviewMode: String {
  case off

  /// 文字（▀）の文字色と背景色で、1文字に上下2つの画素を描く。どの端末でも出る。
  case blocks

  /// iTerm2 の画像表示。
  case iterm

  var label: String {
    switch self {
    case .off: "off"
    case .blocks: "dmp"
    case .iterm: "iTerm"
    }
  }
}

/// ローカルの窓のカーソルの画像・動画を、反対側の窓の上に重ねて出す。
final class PreviewOverlay {
  init(_ app: App) {
    self.app = app
  }

  let app: App

  /// V で off → dmp → iTerm → off の順に切り替える。iTerm2 は画像を出すたびに確認するので
  /// （断るとデータが文字で出る）、最初はオフ。
  var mode = PreviewMode.off

  /// 重ねているプレビュー（描き方と [LocalPane.previewId]）。
  private var id: String?
  private var timer: OneShotTimer?

  /// 作ったプレビュー。iTerm2 は JPEG の base64、標準は [PreviewPixels]。作れなかったものは nil。
  private var previews = OrderedMap<String, Any?>()

  /// 窓の大きさに縮めた画素（縮める元・幅・高さごと）。
  private var fitted: (source: PreviewPixels, w: Int, h: Int, pixels: PreviewPixels)?

  /// 次の描き方にする（V）。
  func cycleMode() {
    let previous = mode
    switch previous {
    case .off: mode = .blocks
    case .blocks where canShowImages: mode = .iterm
    default: mode = .off
    }
    if previous == .iterm {
      // iTerm2 の確認で断ると画像のデータが文字で画面に出るので、やめるときは全体を描き直して消す。
      app.repaint()
    }
  }

  /// プレビューがオンで、ローカルの窓 [local] のカーソルが画像か動画に乗っていれば、その項目と種類。
  func target(_ local: LocalPane) -> (Entry, PreviewKind)? {
    if mode == .off || !local.ready {
      return nil
    }
    guard let entry = local.current, !entry.isDir, let kind = previewKindOf(entry.name) else {
      return nil
    }
    return (entry, kind)
  }

  /// [local] の [entry] のプレビューの窓を描く。画像はカーソルが少し止まってから作る。
  func draw(_ screen: Screen, _ local: LocalPane, _ entry: Entry, _ kind: PreviewKind, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
    let bg = Style()
    let mode = mode
    let id = "\(mode.rawValue)|\(local.previewId(entry))"
    if id != self.id {
      self.id = id
      timer?.cancel()
      if !previews.containsKey(id) {
        timer = OneShotTimer(milliseconds: 150) { [weak self] in
          Task { await self?.load(local, id, entry, kind, mode) }
        }
      }
    }
    screen.fill(x, y, w, h, bg)
    screen.box(
      x, y, w, h, bg.copyWith(fg: Palette.outline),
      title: "Preview (\(mode.label))",
      titleStyle: bg.copyWith(fg: Palette.lime)
    )
    screen.text(x + 1, y + 1, truncate(entry.name, w - 2), bg.copyWith(fg: Palette.muted))
    let data = previews[id] ?? nil
    if data == nil {
      screen.text(x + 2, y + 2, previews.containsKey(id) ? "プレビューできません" : "読み込み中…", bg.copyWith(fg: Palette.muted))
    } else if let pixels = data as? PreviewPixels {
      drawPixels(screen, pixels, x + 1, y + 2, w - 2, h - 3)
    } else if let base64 = data as? String {
      let padding = base64.hasSuffix("==") ? 2 : (base64.hasSuffix("=") ? 1 : 0)
      screen.image = ScreenImage(
        x + 1, y + 2, w - 2, h - 3, id, base64,
        name: Data(entry.name.utf8).base64EncodedString(),
        size: base64.utf8.count / 4 * 3 - padding
      )
    }
  }

  /// 画素を「▀」で描く（文字色が上、背景色が下の画素）。枠の中央に置く。
  private func drawPixels(_ screen: Screen, _ pixels: PreviewPixels, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
    if fitted == nil || fitted!.source !== pixels || fitted!.w != w || fitted!.h != h {
      fitted = (pixels, w, h, pixels.fit(w, h * 2))
    }
    let fitted = fitted!.pixels
    let left = x + (w - fitted.width) / 2
    let rows = (fitted.height + 1) / 2
    let top = y + (h - rows) / 2
    for row in 0..<rows {
      for col in 0..<fitted.width {
        let upper = fitted.at(col, row * 2)
        let lower = row * 2 + 1 < fitted.height ? Rgb(fitted.at(col, row * 2 + 1)) : Palette.background
        screen.text(left + col, top + row, "▀", Style(fg: Rgb(upper), bg: lower))
      }
    }
  }

  private func load(_ local: LocalPane, _ id: String, _ entry: Entry, _ kind: PreviewKind, _ mode: PreviewMode) async {
    var data: Any?
    // 作れなければ「プレビューできません」と出す。
    if mode == .iterm {
      let bytes = try? await local.preview(entry) { path, work in await makePreview(path, kind, work) }
      data = (bytes ?? nil)?.base64EncodedString()
    } else {
      data = (try? await local.preview(entry) { path, work in await makePreviewPixels(path, kind, work) }) ?? nil
    }
    // 古いものから捨て、最近の分だけ覚えておく。
    previews.removeValue(forKey: id)
    previews[id] = .some(data)
    if previews.count > 30, let first = previews.keys.first {
      previews.removeValue(forKey: first)
    }
    app.requestRender()
  }
}
