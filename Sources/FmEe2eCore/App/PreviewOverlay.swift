import AppKit

/// ローカルの窓のカーソルの画像・動画（SSH の窓では画像だけ）を、反対側の窓の上に重ねて出す。
final class PreviewOverlay {
  init(_ app: App) {
    self.app = app
  }

  let app: App

  /// V でオン・オフを切り替える。最初はオフ。
  var on = false

  /// 重ねているプレビュー（[previewId]）。
  private var id: String?
  private var timer: OneShotTimer?

  /// 作ったプレビュー。作れなかったものは nil。
  private var previews = OrderedMap<String, NSImage?>()

  /// プレビューがオンで、窓 [pane] のカーソルがプレビューできるファイルに乗っていれば、その項目と種類。
  /// SSH の窓では、画像だけ（動画は大きく、ファイルをまるごと読まないと1コマも出せないため）。
  func target(_ pane: Pane) -> (Entry, PreviewKind)? {
    if !on || !pane.ready {
      return nil
    }
    guard let entry = pane.current, !entry.isDir, let kind = previewKindOf(entry.name) else {
      return nil
    }
    if let ssh = pane as? SshPane {
      return kind == .image && ssh.ssh != nil && entry.data is RemoteEntry ? (entry, kind) : nil
    }
    return pane is LocalPane ? (entry, kind) : nil
  }

  /// [pane] の [entry] のプレビューの窓を描く。画像はカーソルが少し止まってから作る。
  func draw(_ screen: Screen, _ pane: Pane, _ entry: Entry, _ kind: PreviewKind, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
    let bg = Style()
    let id = previewId(pane, entry)
    if id != self.id {
      self.id = id
      timer?.cancel()
      if !previews.containsKey(id) {
        timer = OneShotTimer(milliseconds: 150) { [weak self] in
          Task { await self?.load(pane, id, entry, kind) }
        }
      }
    }
    screen.fill(x, y, w, h, bg)
    screen.box(x, y, w, h, bg.copyWith(fg: Palette.outline), title: "Preview", titleStyle: bg.copyWith(fg: Palette.lime))
    screen.text(x + 1, y + 1, truncate(entry.name, w - 2), bg.copyWith(fg: Palette.muted))
    if let image = previews[id] ?? nil {
      screen.image = ScreenImage(x + 1, y + 2, w - 2, h - 3, image)
    } else {
      screen.text(x + 2, y + 2, previews.containsKey(id) ? tr("preview_overlay.unavailable") : tr("preview_overlay.loading"), bg.copyWith(fg: Palette.muted))
    }
  }

  /// [entry] のプレビュー用の名前。変わったら作り直す。
  private func previewId(_ pane: Pane, _ entry: Entry) -> String {
    if let local = pane as? LocalPane {
      return local.previewId(entry)
    }
    let modified = entry.modified.map { "\($0.timeIntervalSince1970)" } ?? "null"
    return "\(pane.location)/\(entry.name)|\(entry.size.map(String.init) ?? "null")|\(modified)"
  }

  private func load(_ pane: Pane, _ id: String, _ entry: Entry, _ kind: PreviewKind) async {
    // 作れなければ「プレビューできません」と出す。
    var image: NSImage?
    if let local = pane as? LocalPane {
      image = (try? await local.preview(entry) { path in await makePreview(path, kind) }) ?? nil
    } else if let ssh = pane as? SshPane, let connection = ssh.ssh {
      image = (try? await connection.run("cat \(shQuote(ssh.pathOf(entry)))")).flatMap(makePreview)
    }
    // 古いものから捨て、最近の分だけ覚えておく。
    previews.removeValue(forKey: id)
    previews[id] = .some(image)
    if previews.count > 30, let first = previews.keys.first {
      previews.removeValue(forKey: first)
    }
    app.requestRender()
  }
}
