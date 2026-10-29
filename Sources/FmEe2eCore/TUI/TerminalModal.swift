import Foundation

/// [executable] を、左右の窓の場所を覆う枠の中の端末で動かし、終わったら終了コードを返す。画面は切り替えない。
/// 終了コードで [waitAfterExit] が true なら、終わったあと出力を残して Enter を待つ（エディタなどは待たずに閉じる）。
/// 失敗したときは右下に終了コードを出す。
@discardableResult
func runInTerminal(
  _ app: App,
  _ title: String,
  _ executable: String,
  _ args: [String],
  workingDirectory: String? = nil,
  waitAfterExit: @escaping (_ exitCode: Int) -> Bool = { _ in true }
) async -> Int {
  final class Failure {
    var error: (any Error)?
  }
  let failure = Failure()
  let code = await app.showModal { (close: @escaping (Int) -> Void) -> View in
    let modal = TerminalModal(app, title, close, waitAfterExit: waitAfterExit)
    // 枠を出してから始める。
    Task {
      do {
        try await modal.start(executable, args, workingDirectory: workingDirectory)
      } catch {
        failure.error = error
        modal.abort()
      }
    }
    return modal
  }
  if let failure = failure.error {
    await app.showError(failure)
    return 255
  }
  return code
}

/// プログラムを動かす枠。動いている間はキーをすべてプログラムに渡し、Ctrl+C もプログラムに届ける。
/// 終わったあとは ↑↓ PgUp PgDn で、画面から流れた出力をさかのぼれる。
final class TerminalModal: Modal {
  init(_ app: App, _ title: String, _ close: @escaping (_ exitCode: Int) -> Void, waitAfterExit: @escaping (_ exitCode: Int) -> Bool) {
    self.app = app
    self.close = close
    self.waitAfterExit = waitAfterExit
    terminal = ShellTerminal(max(2, app.terminal.width - 4), max(1, app.terminal.height - 6))
    super.init(title, accent: Palette.cyan)
  }

  let app: App
  let close: (_ exitCode: Int) -> Void

  /// 終わったあと Enter を待つか（終了コードで決める）。
  let waitAfterExit: (_ exitCode: Int) -> Bool
  let terminal: ShellTerminal
  private var session: ShellSession?
  private var input: ShellInput?

  /// 終わったときの終了コード。動いている間は nil。
  private(set) var exitCode: Int?

  /// さかのぼっている行数。0 なら今の画面。
  private var back = 0

  /// プログラムが動いている。
  var running: Bool { exitCode == nil }

  override var frame: ModalFrame { .panel }

  /// 失敗したときだけ、右下に終了コードを出す。
  override var status: (String, Rgb)? {
    if let code = exitCode, code != 0 {
      return (exitStatusText(code), Palette.error)
    }
    return nil
  }

  override var hints: [(String, String)] {
    running
      ? [("Ctrl+C", "中断")]
      : (terminal.scrollback.isEmpty ? [] : [("↑↓ PgUp PgDn", "さかのぼる")]) + [("Enter", "戻る")]
  }

  func start(_ executable: String, _ args: [String], workingDirectory: String? = nil) async throws {
    let session = ShellSession(
      terminal,
      onChange: { [unowned app] in app.requestRender() },
      onExit: { [weak self] in self?.ended($0) }
    )
    self.session = session
    try await session.startCommand(executable, args, workingDirectory: workingDirectory)
    // すぐ終わるプログラムは、ここに来る前に終わっていることがある。
    if !running || !session.running {
      return
    }
    let input = ShellInput(terminal, send: { [weak session] in session?.write($0) })
    self.input = input
    app.terminal.inputFilter = { [weak self] bytes in self?.input?.filter(bytes) ?? bytes }
    app.interrupt = { [weak session] in session?.write([3]) }
    app.requestRender()
  }

  /// 始められなかったとき。片付けて閉じる。
  func abort() {
    release()
    close(255)
  }

  private func ended(_ code: Int) {
    exitCode = code
    release()
    if let session {
      Task { await session.close() }
    }
    if !waitAfterExit(code) {
      close(code)
      return
    }
    app.requestRender()
  }

  /// キーとCtrl+C を、このアプリに戻す。
  private func release() {
    if let input {
      app.terminal.inputFilter = nil
      app.interrupt = nil
      input.dispose()
      self.input = nil
    }
  }

  override func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ width: Int) {
    let rows = bodyRows
    if terminal.columns != width || terminal.rows != rows {
      if let session, session.running {
        session.resize(width, rows)
      } else {
        terminal.resize(width, rows)
      }
    }
    screen.fill(x, y, width, rows, Style())
    let scrollback = terminal.scrollback
    back = min(max(back, 0), scrollback.count)
    let top = scrollback.count - back
    let visible = min(terminal.rows, rows)
    let links = self.links(top, visible)
    for row in 0..<max(0, visible) {
      let index = top + row
      let line = self.line(index)
      var col = 0
      while col < line.count && col < width {
        let cell = line[col]
        if !cell.text.isEmpty {
          let link = links[CellPosition(index, col)]
          screen.text(
            x + col,
            y + row,
            cell.text,
            link == nil ? cell.style : cell.style.copyWith(link: link),
            maxWidth: width - col
          )
        }
        col += 1
      }
    }
    if running && back == 0 && terminal.cursorVisible {
      screen.cursor = (x + terminal.x, y + terminal.y)
    }
  }

  /// 流れた行と今の画面を通した [index] 行目のセル。
  private func line(_ index: Int) -> [ShellCell] {
    let scrollback = terminal.scrollback
    if index < scrollback.count {
      return scrollback[index]
    }
    return (0..<terminal.columns).map { terminal.cell($0, index - scrollback.count) }
  }

  /// 最後の列まで文字がある行（次の行へ折り返して続いているかもしれない）。
  private static func full(_ line: [ShellCell]) -> Bool { !line.isEmpty && line[line.count - 1].text != " " }

  /// 行・列の組（Dart のレコード (int, int) の代わり）。
  private struct CellPosition: Hashable {
    init(_ row: Int, _ col: Int) {
      self.row = row
      self.col = col
    }

    let row: Int
    let col: Int
  }

  /// [top] 行目から [count] 行に出ている URL の、セル（行・列）ごとのリンク先。
  /// 端で折り返された URL は、前後の行とつないで1本の URL にする（git push のあとの PR のリンクなど）。
  private func links(_ top: Int, _ count: Int) -> [CellPosition: String] {
    let total = terminal.scrollback.count + terminal.rows
    // 見えている行の前後へ、折り返しでつながっている行まで広げる（URL の長さとして十分な行数まで）。
    let reach = 8
    var first = top
    while first > max(0, top - reach) && TerminalModal.full(line(first - 1)) {
      first -= 1
    }
    var last = min(total, top + count) - 1
    let end = min(total, top + count + reach)
    while last + 1 < end && TerminalModal.full(line(last)) {
      last += 1
    }
    var links: [CellPosition: String] = [:]
    // 正規表現の位置は UTF-16 で数えるので、セルも UTF-16 の1単位ごとに並べる（Dart と同じ）。
    var text = ""
    var cells: [CellPosition] = []
    func flush() {
      let s = text as NSString
      for match in TerminalModal.urlPattern.matches(in: text, range: NSRange(location: 0, length: s.length)) {
        let url = TerminalModal.trimTrailing(s.substring(with: match.range))
        for i in match.range.location..<(match.range.location + url.utf16.count) {
          links[cells[i]] = url
        }
      }
      text = ""
      cells.removeAll()
    }

    if first <= last {
      for index in first...last {
        let line = self.line(index)
        for col in 0..<line.count {
          for _ in 0..<line[col].text.utf16.count {
            cells.append(CellPosition(index, col))
          }
          text += line[col].text
        }
        if !TerminalModal.full(line) {
          flush()
        }
      }
    }
    flush()
    return links
  }

  private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>"'`]+"#)

  /// URL の末尾の句読点・閉じ括弧（`[.,;:!?)\]}>]+$`）を除く。
  private static func trimTrailing(_ url: String) -> String {
    var scalars = url.unicodeScalars
    while let last = scalars.last, ".,;:!?)]}>".unicodeScalars.contains(last) {
      scalars.removeLast()
    }
    return String(scalars)
  }

  /// 終わったあとのキー（動いている間のキーはプログラムに渡している）。
  override func handleKey(_ key: Key) {
    if running {
      return
    }
    let page = max(1, bodyRows - 1)
    switch key.name {
    case "enter", "escape":
      close(exitCode!)
    case "up":
      back += 1
    case "down":
      back -= 1
    case "pageUp":
      back += page
    case "pageDown":
      back -= page
    case "home":
      back = terminal.scrollback.count
    case "end":
      back = 0
    case "char" where key.isLetter("q"):
      close(exitCode!)
    default:
      break
    }
    back = min(max(back, 0), terminal.scrollback.count)
  }
}
