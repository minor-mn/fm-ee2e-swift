/// 端末と同じ形のバイト列（キー・エスケープシーケンス・bracketed paste）を [Key] にする。
/// 窓（[GridView]）は、キー入力を端末と同じバイト列にして渡す。
final class KeyDecoder {
  init() {}

  let keys = Broadcast<Key>()
  private var keyEvents: Broadcast<Key> { keys }
  private var pending: [UInt8] = []
  private var pasteBuffer: [UInt8] = []
  private var inPaste = false
  private var escapeTimer: OneShotTimer?

  /// 解釈しかけのバイト列を捨てる。
  func reset() {
    escapeTimer?.cancel()
    pending.removeAll()
  }

  /// 届いたバイト列を解釈する。
  func feed(_ bytes: [UInt8]) {
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
