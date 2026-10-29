import Darwin
import Foundation

/// キー入力。特殊キーは [name]、文字は [char]、Ctrl+英字は [ctrl] に英小文字、貼り付けは [paste]。
struct Key: CustomStringConvertible {
  private init(name: String, char: String? = nil, ctrl: String? = nil, paste: String? = nil) {
    self.name = name
    self.char = char
    self.ctrl = ctrl
    self.paste = paste
  }

  static func named(_ name: String) -> Key { Key(name: name) }
  static func char(_ char: String) -> Key { Key(name: "char", char: char) }
  static func ctrl(_ ctrl: String) -> Key { Key(name: "ctrl", ctrl: ctrl) }
  static func paste(_ paste: String) -> Key { Key(name: "paste", paste: paste) }

  let name: String
  let char: String?
  let ctrl: String?
  let paste: String?

  var isChar: Bool { char != nil }

  /// 英字は大文字・小文字を区別しない（FDと同じ）。
  func isLetter(_ letter: String) -> Bool { char != nil && char!.lowercased() == letter.lowercased() }

  var description: String { char ?? (ctrl != nil ? "Ctrl+\(ctrl!)" : name) }
}

/// シグナルを受け取る。ハンドラーは子プロセスで既定に戻る（無視にすると子プロセスにも引き継がれる）。
func watchSignal(_ signo: Int32, _ handler: @escaping () -> Void) -> DispatchSourceSignal {
  signal(signo) { _ in }
  let source = DispatchSource.makeSignalSource(signal: signo, queue: .main)
  source.setEventHandler { MainActor.assumeIsolated { handler() } }
  source.resume()
  return source
}

/// 標準出力に書く（バッファーせずにすぐ書く）。
func writeStdout(_ s: String) {
  var data = Array(s.utf8)
  var offset = 0
  while offset < data.count {
    let n = data.withUnsafeMutableBytes { Darwin.write(1, $0.baseAddress! + offset, $0.count - offset) }
    if n <= 0 {
      if n < 0 && errno == EINTR { continue }
      return
    }
    offset += n
  }
  data.removeAll()
}

func writeStderr(_ s: String) {
  FileHandle.standardError.write(Data(s.utf8))
}

/// 端末のRawモードと代替画面。終了時に必ず [restore] を呼ぶ。
final class Terminal {
  init() {}

  private let keyEvents = Broadcast<Key>()
  private let resizeEvents = Broadcast<Void>()
  private var signalSources: [DispatchSourceSignal] = []
  private var pending: [UInt8] = []
  private var pasteBuffer: [UInt8] = []
  private var inPaste = false
  private var escapeTimer: OneShotTimer?
  private var active = false
  private var poll: PeriodicTimer?
  private var original: termios?

  /// 子プロセスに端末を渡している間は false にして、キーを読まない。
  private var reading = true

  /// 別のプログラムに端末を渡している間は true。
  private(set) var suspended = false

  var keys: Broadcast<Key> { keyEvents }
  var resizes: Broadcast<Void> { resizeEvents }

  /// 組み込みシェルなどへ生の入力を渡す。返したバイトだけを通常のキーとして解釈する。
  var inputFilter: (([UInt8]) -> [UInt8])?

  private var size: (columns: Int, lines: Int)? {
    var ws = winsize()
    guard isatty(1) != 0, ioctl(1, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 else {
      return nil
    }
    return (Int(ws.ws_col), Int(ws.ws_row))
  }

  var width: Int { size?.columns ?? 80 }
  var height: Int { size?.lines ?? 24 }

  /// 入力を1文字ずつ、表示せずに読む（Ctrl+C などのシグナルはそのまま）。
  private func setRaw(_ raw: Bool) {
    guard let original else { return }
    var t = original
    if raw {
      t.c_lflag &= ~tcflag_t(ECHO | ECHONL | ICANON | IEXTEN)
      // VMIN・VTIME を設定し、1バイトでも読めるようにする。
      withUnsafeMutableBytes(of: &t.c_cc) { cc in
        cc[Int(VMIN)] = 1
        cc[Int(VTIME)] = 0
      }
    }
    tcsetattr(0, TCSANOW, &t)
  }

  func start() throws {
    if isatty(0) == 0 {
      throw AppError("端末から起動してください。")
    }
    var t = termios()
    tcgetattr(0, &t)
    original = t
    setRaw(true)
    active = true
    // 代替画面、カーソル非表示、貼り付けの括弧付き入力（bracketed paste）。
    write("\u{1b}[?1049h\u{1b}[?25l\u{1b}[?2004h\u{1b}[2J")
    poll = PeriodicTimer(milliseconds: 10) { [weak self] in self?.readInput() }
    signalSources.append(watchSignal(SIGWINCH) { [weak self] in self?.resizeEvents.add(()) })
  }

  /// 通常の画面と入力モードに戻し、キーの読み取りを止める（子プロセスに端末を渡す）。
  func suspend() {
    suspended = true
    reading = false
    escapeTimer?.cancel()
    pending.removeAll()
    write("\u{1b}[0m\u{1b}[?2004l\u{1b}[?25h\u{1b}[?1049l")
    setRaw(false)
  }

  /// [suspend] の後、代替画面に戻る。[waitFor] があれば、それに当たるキーが押されるのを待ってから戻る。
  func resume(waitFor: ((Key) -> Bool)? = nil) async {
    setRaw(true)
    reading = true
    if let waitFor {
      _ = await keys.first(where: waitFor)
    }
    suspended = false
    write("\u{1b}[?1049h\u{1b}[?25l\u{1b}[?2004h\u{1b}[2J")
  }

  /// 読めるだけ読んで解釈する。止めている間は読まない（子プロセスへのキーを横取りしない）。
  private func readInput() {
    while reading {
      guard let bytes = readTty() else {
        return
      }
      onBytes(bytes)
    }
  }

  /// 待たずに読めた分を返す。読めるものがなければ nil。
  private func readTty() -> [UInt8]? {
    var fds = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
    if Darwin.poll(&fds, 1, 0) <= 0 || fds.revents & Int16(POLLIN) == 0 {
      return nil
    }
    var buffer = [UInt8](repeating: 0, count: 4096)
    let n = buffer.withUnsafeMutableBytes { Darwin.read(0, $0.baseAddress, $0.count) }
    return n <= 0 ? nil : Array(buffer[0..<n])
  }

  func restore() {
    if !active {
      return
    }
    active = false
    escapeTimer?.cancel()
    write("\u{1b}[0m\u{1b}[?2004l\u{1b}[?25h\u{1b}[?1049l")
    poll?.cancel()
    setRaw(false)
    for s in signalSources {
      s.cancel()
    }
  }

  func write(_ s: String) {
    writeStdout(s)
  }

  private func onBytes(_ input: [UInt8]) {
    let bytes = inputFilter?(input) ?? input
    if bytes.isEmpty { return }
    escapeTimer?.cancel()
    pending.append(contentsOf: bytes)
    parse()
    // ESC単独なのか、エスケープシーケンスの途中なのかを少し待って判断する。
    if pending.first == 0x1b {
      escapeTimer = OneShotTimer(milliseconds: 40) { [weak self] in
        guard let self else { return }
        if pending.count == 1 && pending.first == 0x1b {
          pending.removeAll()
          keyEvents.add(.named("escape"))
        } else if !pending.isEmpty {
          // 解釈できないシーケンスは捨てる。
          pending.removeAll()
        }
      }
    }
  }

  private func parse() {
    while !pending.isEmpty {
      if inPaste {
        guard let end = Self.indexOf(pending, Self.pasteEnd) else {
          // 終端の一部が来ている可能性があるので、末尾は残す。
          let safe = pending.count - Self.pasteEnd.count
          if safe > 0 {
            pasteBuffer.append(contentsOf: pending[0..<safe])
            pending.removeSubrange(0..<safe)
          }
          return
        }
        pasteBuffer.append(contentsOf: pending[0..<end])
        pending.removeSubrange(0..<(end + Self.pasteEnd.count))
        inPaste = false
        let text = String(decoding: pasteBuffer, as: UTF8.self)
        keyEvents.add(.paste(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")))
        pasteBuffer.removeAll()
        continue
      }
      let b = pending[0]
      if b == 0x1b {
        if parseEscape() == 0 {
          return
        }
        continue
      }
      if b < 0x20 || b == 0x7f {
        pending.removeFirst()
        let key: Key? =
          switch b {
          case 0x0d, 0x0a: .named("enter")
          case 0x09: .named("tab")
          case 0x7f, 0x08: .named("backspace")
          case 0x00: nil
          default: .ctrl(String(UnicodeScalar(b + 0x60)))
          }
        if let key {
          keyEvents.add(key)
        }
        continue
      }
      // UTF-8 の1文字分がそろっていなければ待つ。
      let length = b < 0x80 ? 1 : (b >= 0xf0 ? 4 : (b >= 0xe0 ? 3 : (b >= 0xc0 ? 2 : 1)))
      if pending.count < length {
        return
      }
      let ch = String(decoding: pending[0..<length], as: UTF8.self)
      pending.removeSubrange(0..<length)
      keyEvents.add(.char(ch))
    }
  }

  private static let pasteStart = Array("\u{1b}[200~".utf8)
  private static let pasteEnd = Array("\u{1b}[201~".utf8)

  /// 先頭のエスケープシーケンスを解釈して消費したバイト数を返す。途中なら0。
  private func parseEscape() -> Int {
    if pending.count < 2 {
      return 0
    }
    let second = pending[1]
    if second == 0x5b /* [ */ {
      // CSI: パラメーター（0x30–0x3f）に続いて終端（0x40–0x7e）。
      var i = 2
      while i < pending.count && pending[i] >= 0x30 && pending[i] <= 0x3f {
        i += 1
      }
      if i >= pending.count {
        return 0
      }
      let seq = Array(pending[0...i])
      pending.removeSubrange(0...i)
      if seq.starts(with: Self.pasteStart) {
        inPaste = true
        return seq.count
      }
      if let key = Self.csiKeys[String(decoding: seq, as: UTF8.self)] {
        keyEvents.add(.named(key))
      }
      return seq.count
    }
    if second == 0x4f /* O */ {
      if pending.count < 3 {
        return 0
      }
      let seq = String(decoding: pending[0..<3], as: UTF8.self)
      pending.removeSubrange(0..<3)
      if let key = Self.ss3Keys[seq] {
        keyEvents.add(.named(key))
      }
      return 3
    }
    // Alt+キーなど。ESCとして扱い、続くバイトは次に解釈する。
    pending.removeFirst()
    keyEvents.add(.named("escape"))
    return 1
  }

  private static let csiKeys: [String: String] = [
    "\u{1b}[A": "up",
    "\u{1b}[B": "down",
    "\u{1b}[C": "right",
    "\u{1b}[D": "left",
    "\u{1b}[H": "home",
    "\u{1b}[F": "end",
    "\u{1b}[1~": "home",
    "\u{1b}[4~": "end",
    "\u{1b}[7~": "home",
    "\u{1b}[8~": "end",
    "\u{1b}[2~": "insert",
    "\u{1b}[3~": "delete",
    "\u{1b}[5~": "pageUp",
    "\u{1b}[6~": "pageDown",
    "\u{1b}[Z": "backTab",
    "\u{1b}[15~": "f5",
    "\u{1b}[17~": "f6",
    "\u{1b}[18~": "f7",
    "\u{1b}[19~": "f8",
    "\u{1b}[20~": "f9",
    "\u{1b}[21~": "f10",
    "\u{1b}[23~": "f11",
    "\u{1b}[24~": "f12",
    "\u{1b}[11~": "f1",
    "\u{1b}[12~": "f2",
    "\u{1b}[13~": "f3",
    "\u{1b}[14~": "f4",
  ]

  private static let ss3Keys: [String: String] = [
    "\u{1b}OA": "up",
    "\u{1b}OB": "down",
    "\u{1b}OC": "right",
    "\u{1b}OD": "left",
    "\u{1b}OH": "home",
    "\u{1b}OF": "end",
    "\u{1b}OP": "f1",
    "\u{1b}OQ": "f2",
    "\u{1b}OR": "f3",
    "\u{1b}OS": "f4",
  ]

  private static func indexOf(_ list: [UInt8], _ pattern: [UInt8]) -> Int? {
    if list.count < pattern.count {
      return nil
    }
    for i in 0...(list.count - pattern.count) where list[i..<(i + pattern.count)].elementsEqual(pattern) {
      return i
    }
    return nil
  }
}
