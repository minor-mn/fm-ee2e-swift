import Foundation

/// 画面全体（鍵の設定・ログイン・メイン画面）またはその上のダイアログ。
protocol View: AnyObject {
  func draw(_ screen: Screen)

  /// キーを処理する。
  func handleKey(_ key: Key)
}

/// 描画とキー入力の振り分け。ダイアログは積み重ね、最前面だけがキーを受け取る。
final class App {
  init(_ terminal: Terminal) {
    self.terminal = terminal
  }

  let terminal: Terminal
  var root: View!
  private var modals: [View] = []
  private var previous: Screen?
  private var scheduled = false
  private var done = false
  private var doneWaiters: [CheckedContinuation<Void, Never>] = []

  var hasModal: Bool { !modals.isEmpty }

  /// Ctrl+C を、このアプリの終了ではなく、枠の中で動かしているプログラムに届けるとき。
  var interrupt: (() -> Void)?

  func run(_ initial: View) async {
    root = initial
    terminal.keys.listen { [unowned self] key in
      if terminal.suspended {
        return
      }
      let target = modals.last ?? root!
      target.handleKey(key)
      requestRender()
    }
    terminal.resizes.listen { [unowned self] in
      previous = nil
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

  /// 端末を [action]（子プロセスなど）に渡し、終わったら画面に戻る。
  /// 戻る前にキー（[enterToReturn] なら Enter）を待つ。[waitForKey] が結果を見て false を返したときは待たない。
  func runExternal<T>(
    _ action: () async throws -> T,
    waitForKey: ((T) -> Bool)? = nil,
    enterToReturn: Bool = false
  ) async throws -> T {
    terminal.suspend()
    do {
      let result = try await action()
      let wait = waitForKey?(result) ?? true
      await returnFromExternal(wait: wait, enterToReturn: enterToReturn)
      return result
    } catch {
      await returnFromExternal(wait: true, enterToReturn: enterToReturn)
      throw error
    }
  }

  private func returnFromExternal(wait: Bool, enterToReturn: Bool) async {
    if wait {
      terminal.write("\n\u{1b}[7m \(enterToReturn ? "Enter で戻ります" : "何かキーを押すと戻ります")\u{1b}[0m")
    }
    await terminal.resume(waitFor: !wait ? nil : (enterToReturn ? { $0.name == "enter" } : { _ in true }))
    previous = nil
    requestRender()
  }

  /// 前回の画面を忘れて、すべて描き直す（端末側で画面が汚れたとき）。
  func repaint() {
    previous = nil
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
    if done || terminal.suspended || root == nil {
      return
    }
    let screen = Screen(terminal.width, terminal.height)
    screen.fill(0, 0, screen.width, screen.height, Style())
    root.draw(screen)
    if !modals.isEmpty {
      // 画像はダイアログより上に出てしまうので、ダイアログを開いている間は出さない。
      screen.image = nil
    }
    for modal in modals {
      screen.cursor = nil
      modal.draw(screen)
    }
    terminal.write(screen.diff(previous))
    previous = screen
  }
}
