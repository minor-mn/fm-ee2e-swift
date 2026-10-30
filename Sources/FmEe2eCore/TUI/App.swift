import Foundation

/// 画面全体（鍵の設定・ログイン・メイン画面）またはその上のダイアログ。
protocol View: AnyObject {
  func draw(_ screen: Screen)

  /// キーを処理する。
  func handleKey(_ key: Key)
}

/// 描画とキー入力の振り分け。ダイアログは積み重ね、最前面だけがキーを受け取る。
final class App {
  init(_ host: Host) {
    self.host = host
  }

  let host: Host
  var root: View!
  private var modals: [View] = []
  private var scheduled = false
  private var done = false
  private var doneWaiters: [CheckedContinuation<Void, Never>] = []

  var hasModal: Bool { !modals.isEmpty }

  /// 選んでいる窓のタブの見た目。枠の中の端末（[TerminalModal]）はこの見た目で描く。
  var activeTheme = ThemeKey.defaults

  /// 窓全体の見た目で幅 [width]・高さ [height] の範囲に、見た目 [theme] のセルが何桁・何行入るか。
  func gridSize(_ width: Int, _ height: Int, theme: ThemeKey) -> (Int, Int) {
    host.sizer?.gridSize(width, height, from: .window, to: theme) ?? (width, height)
  }

  func run(_ initial: View) async {
    root = initial
    host.keys.listen { [unowned self] key in
      let target = modals.last ?? root!
      target.handleKey(key)
      requestRender()
    }
    host.resizes.listen { [unowned self] in
      requestRender()
    }
    requestRender()
    if done {
      return
    }
    await withCheckedContinuation { doneWaiters.append($0) }
  }

  func quit() {
    if done {
      return
    }
    done = true
    for waiter in doneWaiters {
      waiter.resume()
    }
    doneWaiters.removeAll()
  }

  func setRoot(_ view: View) {
    root = view
    requestRender()
  }

  /// ダイアログを開き、close が呼ばれるまで待つ。
  func showModal<T>(_ build: (@escaping (T) -> Void) -> View) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
      var completed = false
      weak var shown: View?
      let view = build { [unowned self] result in
        if let shown {
          modals.removeAll { $0 === shown }
        }
        requestRender()
        if !completed {
          completed = true
          continuation.resume(returning: result)
        }
      }
      shown = view
      modals.append(view)
      requestRender()
    }
  }

  /// 結果を待たないダイアログ（処理中の表示など）を開き、閉じる関数を返す。
  func openModal(_ view: View) -> () -> Void {
    modals.append(view)
    requestRender()
    return { [unowned self] in
      modals.removeAll { $0 === view }
      requestRender()
    }
  }

  /// ステータスバー（下に出している状態の表示）。しばらくすると消える。
  private var status: String?
  private var statusTimer: OneShotTimer?

  /// 状態を、キー操作の要らないステータスバーに出す（ダイアログは出さない）。4秒で消える。
  func showStatus(_ text: String) {
    status = text
    statusTimer?.cancel()
    statusTimer = OneShotTimer(milliseconds: 4000) { [weak self] in
      self?.status = nil
      self?.requestRender()
    }
    requestRender()
  }

  func requestRender() {
    if scheduled {
      return
    }
    scheduled = true
    DispatchQueue.main.async { MainActor.assumeIsolated { self.render() } }
  }

  private func render() {
    scheduled = false
    if done || root == nil {
      return
    }
    Theme.active = Appearance.current.window
    let screen = Screen(host.width, host.height, sizer: host.sizer)
    screen.fill(0, 0, screen.width, screen.height, Style())
    root.draw(screen)
    if !modals.isEmpty {
      // 画像はダイアログより上に出てしまうので、ダイアログを開いている間は出さない。
      screen.removeImages()
    }
    // ダイアログは、透明な画面に描いて重ねる（GUI 版では、下の窓の文字の大きさが違っても上に出る）。
    for modal in modals {
      screen.removeCursors()
      screen.layer(0, 0, screen.width, screen.height, theme: .window, clear: true) { modal.draw($0) }
    }
    // ステータスバーは、ダイアログを含めていちばん上の、下から2行目の右に出す。
    if let status {
      screen.layer(0, 0, screen.width, screen.height, theme: .window, clear: true) { s in
        let text = " \(truncate(status, max(0, s.width - 4))) "
        s.text(max(0, s.width - 1 - textWidth(text)), s.height - 2, text, Style(fg: Palette.statusbar, bg: Palette.surfaceHigh))
      }
    }
    host.present(screen)
  }
}
