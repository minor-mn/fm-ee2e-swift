import Darwin
import Foundation

/// macOS 標準の script でプログラムに専用の PTY を割り当て、枠の中の端末（[ShellTerminal]）で動かす。
/// すべての入出力はアプリ内で扱い、記録は /dev/null に捨てる。
final class ShellSession {
  init(_ terminal: ShellTerminal, onChange: @escaping () -> Void, onExit: @escaping (Int) -> Void) {
    self.terminal = terminal
    self.onChange = onChange
    self.onExit = onExit
  }

  let terminal: ShellTerminal
  let onChange: () -> Void
  let onExit: (Int) -> Void
  private var process: RunningProcess?
  private var shellPid: Int32?
  private var tty: String?
  private var header = ""

  /// 標準出力の末尾（終了状態を読むため）。
  private var tail: [UInt8] = []
  private let ready = Latch<Void>()
  private let ended = Latch<Int>()
  private var stdoutDecoder = Utf8Chunks()
  private var stderrDecoder = Utf8Chunks()
  private var closed = false
  private var resizing = false
  private var size: (Int, Int)?
  var running: Bool { process != nil && ended.value == nil && !closed }
  var exitCode: Int {
    get async { await ended.wait()! }
  }

  /// [executable] を [workingDirectory] で動かす。[environment] は今の環境変数に足す。
  func startCommand(
    _ executable: String,
    _ args: [String],
    workingDirectory: String? = nil,
    environment: [String: String] = [:]
  ) async throws {
    if process != nil || closed {
      throw AppError(tr("shell_session.already_started"))
    }
    terminal.onResponse = { [weak self] in self?.writeText($0) }
    // Process は子を別のプロセスグループで起動するので、外側の Ctrl+C のシグナルは script に届かない。
    let process = try RunningProcess(
      "/bin/sh",
      [
        "-c",
        #"/usr/bin/script "$@"; code=$?; printf "\033]999;fm-exit=%s\007" "$code""#,
        "fm-ee2e-session",
        "-q",
        "/dev/null",
        "/bin/sh",
        "-c",
        #"printf "__FM_SSH_PTY__%s:%s\n" "$$" "$(/usr/bin/tty)"; "#
          + #"/bin/stty rows "$1" columns "$2"; shift 2; exec "$@""#,
        "fm-ee2e-shell",
        "\(terminal.rows)",
        "\(terminal.columns)",
        executable,
      ] + args,
      workingDirectory: workingDirectory,
      environment: environment.merging(["TERM": "xterm-256color"]) { _, new in new }
    )
    self.process = process
    process.onStdout = { [weak self] data in
      guard let self else { return }
      output(stdoutDecoder.decode(data), data)
    }
    process.onStderr = { [weak self] data in
      guard let self else { return }
      display(stderrDecoder.decode(data))
    }
    // 終了コードは、ラッパーが出す末尾の終了状態を読む（script 自身の終了コードではなく、中のプログラムのもの）。
    Task { [weak self] in
      await process.waitForOutput()
      guard let self else { return }
      let rest = stdoutDecoder.finish()
      if !rest.isEmpty {
        output(rest, Data())
      }
      display(stderrDecoder.finish())
      let code = exitStatus() ?? 255
      ready.complete(())
      ended.complete(code)
      if !closed {
        onExit(code)
      }
    }
    if await ready.wait(timeoutMilliseconds: 5000) == nil {
      await close()
      throw AppError(tr("shell_session.start_failed"))
    }
    if tty == nil {
      await close()
      throw AppError(tr("shell_session.start_failed"))
    }
  }

  /// 末尾の `ESC ] 999 ; fm-exit=数字 BEL` の数字。
  private func exitStatus() -> Int? {
    guard tail.last == 7 else { return nil }
    let marker = Array("\u{1b}]999;fm-exit=".utf8)
    let digits = tail.dropLast().reversed().prefix { $0 >= 0x30 && $0 <= 0x39 }.reversed()
    let end = tail.count - 1 - digits.count
    guard !digits.isEmpty, end >= marker.count, Array(tail[(end - marker.count)..<end]) == marker else {
      return nil
    }
    return Int(String(decoding: digits, as: UTF8.self))
  }

  private func output(_ text: String, _ data: Data) {
    tail.append(contentsOf: data)
    if tail.count > 256 {
      tail.removeFirst(tail.count - 256)
    }
    if tty != nil {
      display(text)
      return
    }
    header += text
    let hasLine = header.unicodeScalars.contains("\n")
    if !hasLine && header.utf16.count < 4096 {
      return
    }
    if let (pid, path, rest) = parseHeader(header) {
      shellPid = pid
      tty = path
      display(rest)
      header = ""
      ready.complete(())
      if size != nil {
        Task { await applySize() }
      }
    } else {
      display(header)
      header = ""
      ready.complete(())
    }
  }

  /// 先頭の `__FM_SSH_PTY__PID:/dev/ttysN` の行を読み、PID・TTY・残りの出力を返す。
  private func parseHeader(_ text: String) -> (Int32, String, String)? {
    let scalars = Array(text.unicodeScalars)
    let prefix = Array("__FM_SSH_PTY__".unicodeScalars)
    guard scalars.starts(with: prefix) else { return nil }
    var i = prefix.count
    func digits() -> String {
      var s = ""
      while i < scalars.count && scalars[i].properties.numericType == .decimal && scalars[i].isASCII {
        s.unicodeScalars.append(scalars[i])
        i += 1
      }
      return s
    }
    let pid = digits()
    guard !pid.isEmpty, let pidValue = Int32(pid), i < scalars.count, scalars[i] == ":" else { return nil }
    i += 1
    let devicePrefix = Array("/dev/ttys".unicodeScalars)
    guard Array(scalars.dropFirst(i).prefix(devicePrefix.count)) == devicePrefix else { return nil }
    i += devicePrefix.count
    let number = digits()
    guard !number.isEmpty else { return nil }
    if i < scalars.count && scalars[i] == "\r" {
      i += 1
    }
    guard i < scalars.count && scalars[i] == "\n" else { return nil }
    i += 1
    var rest = ""
    rest.unicodeScalars.append(contentsOf: scalars[i...])
    return (pidValue, "/dev/ttys\(number)", rest)
  }

  private func display(_ text: String) {
    if closed {
      return
    }
    terminal.write(text)
    onChange()
  }

  func write(_ bytes: [UInt8]) {
    if !running {
      return
    }
    // 切断直後に到着したキーは捨てる。
    process!.write(Data(bytes))
  }

  func writeText(_ text: String) { write(Array(text.utf8)) }

  func resize(_ columns: Int, _ rows: Int) {
    terminal.resize(columns, rows)
    size = (terminal.columns, terminal.rows)
    Task { await applySize() }
  }

  private func applySize() async {
    if resizing || tty == nil || !running {
      return
    }
    resizing = true
    defer {
      resizing = false
    }
    do {
      while let size, running {
        self.size = nil
        // slave のサイズ変更はカーネルが SSH に SIGWINCH を届ける。
        try await runProcess("/bin/stty", ["-f", tty!, "columns", "\(size.0)", "rows", "\(size.1)"])
      }
    } catch {
      // 終了とリサイズが重なったときなど。セッションの終了通知で画面を更新する。
    }
  }

  func close() async {
    if closed {
      return
    }
    closed = true
    terminal.onResponse = nil
    guard let process else { return }
    if ended.value == nil {
      // script の子はセッションリーダー。SSH とその子のプロセス群に終了を届ける。
      if let pid = shellPid {
        Darwin.kill(-pid, SIGHUP)
      }
      Darwin.kill(-process.pid, SIGHUP)
      if await ended.wait(timeoutMilliseconds: 2000) == nil {
        if let pid = shellPid {
          Darwin.kill(-pid, SIGKILL)
        }
        Darwin.kill(-process.pid, SIGKILL)
      }
    }
    process.closeStdin()
    process.onStdout = nil
    process.onStderr = nil
  }
}

/// 一度だけ値が決まるもの（Dart の Completer の代わり）。
private final class Latch<T> {
  private(set) var value: T?
  private var waiters: [Int: CheckedContinuation<T?, Never>] = [:]
  private var nextId = 0

  func complete(_ result: T) {
    if value != nil {
      return
    }
    value = result
    let all = waiters
    waiters.removeAll()
    for (_, waiter) in all {
      waiter.resume(returning: result)
    }
  }

  /// 値が決まるまで待つ。[timeoutMilliseconds] を過ぎたら nil。
  func wait(timeoutMilliseconds: Int? = nil) async -> T? {
    if let value {
      return value
    }
    nextId += 1
    let id = nextId
    var timer: OneShotTimer?
    let result = await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
      waiters[id] = continuation
      if let timeoutMilliseconds {
        timer = OneShotTimer(milliseconds: timeoutMilliseconds) { [weak self] in
          self?.waiters.removeValue(forKey: id)?.resume(returning: nil)
        }
      }
    }
    timer?.cancel()
    return result
  }
}

/// 読めた順に届くバイト列を UTF-8 として読む。文字の途中で切れた分は次に回す（不正なバイトは置き換える）。
private struct Utf8Chunks {
  private var pending: [UInt8] = []

  mutating func decode(_ data: Data) -> String {
    pending.append(contentsOf: data)
    // 末尾の、まだそろっていない文字の先頭を探す。
    var cut = pending.count
    var i = pending.count - 1
    while i >= 0 && i >= pending.count - 3 {
      let b = pending[i]
      if b & 0xc0 != 0x80 {
        let length = b >= 0xf0 ? 4 : (b >= 0xe0 ? 3 : (b >= 0xc0 ? 2 : 1))
        if i + length > pending.count {
          cut = i
        }
        break
      }
      i -= 1
    }
    let text = String(decoding: pending[0..<cut], as: UTF8.self)
    pending.removeFirst(cut)
    return text
  }

  mutating func finish() -> String {
    let text = String(decoding: pending, as: UTF8.self)
    pending.removeAll()
    return text
  }
}

/// 枠の中で動かしているプログラムへの入力。Tab・矢印・Ctrl キー・UTF-8 をそのまま渡す。
/// 外側の端末の bracketed paste は、接続先が有効にしたときだけ転送する。
final class ShellInput {
  init(_ terminal: ShellTerminal, send: @escaping ([UInt8]) -> Void) {
    self.terminal = terminal
    self.send = send
  }

  let terminal: ShellTerminal
  let send: ([UInt8]) -> Void
  private var pending: [UInt8] = []
  private var inPaste = false
  private var pasteFramed = false
  private var timer: OneShotTimer?
  private static let start = Array("\u{1b}[200~".utf8)
  private static let end = Array("\u{1b}[201~".utf8)

  func filter(_ bytes: [UInt8]) -> [UInt8] {
    timer?.cancel()
    pending.append(contentsOf: bytes)
    var out: [UInt8] = []
    while !pending.isEmpty {
      let marker = inPaste ? ShellInput.end : ShellInput.start
      var prefix = true
      for i in 0..<ShellInput.minLength(pending.count, marker.count) where pending[i] != marker[i] {
        prefix = false
        break
      }
      if prefix && pending.count < marker.count {
        timer = OneShotTimer(milliseconds: 40) { [weak self] in
          guard let self else { return }
          if !pending.isEmpty {
            send(pending)
          }
          pending.removeAll()
        }
        break
      }
      if prefix {
        if !inPaste {
          pasteFramed = terminal.bracketedPaste
        }
        if pasteFramed {
          out.append(contentsOf: marker)
        }
        pending.removeSubrange(0..<marker.count)
        inPaste.toggle()
      } else {
        // 外側の端末にはアプリケーションカーソルモードを設定しないため、ここで変換する。
        if !inPaste && pending.count >= 3 && pending[0] == 27 && (pending[1] == 91 || pending[1] == 79)
          && Array("ABCDHF".utf8).contains(pending[2])
        {
          out.append(contentsOf: [27, terminal.applicationCursor ? 79 : 91, pending[2]])
          pending.removeSubrange(0..<3)
          continue
        }
        out.append(pending.removeFirst())
      }
    }
    if !out.isEmpty {
      send(out)
    }
    return []
  }

  static func minLength(_ a: Int, _ b: Int) -> Int { a < b ? a : b }

  func dispose() {
    timer?.cancel()
    pending.removeAll()
  }
}
