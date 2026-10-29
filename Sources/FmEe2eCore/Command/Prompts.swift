import Foundation

/// 同名ファイルがあったときの確認。
final class ConflictDialog: Modal {
  init(_ path: String, _ close: @escaping (ConflictDecision?) -> Void) {
    self.path = path
    self.close = close
    super.init("同じ名前のファイル・フォルダーがあります", accent: Palette.lime)
  }

  let path: String
  let close: (ConflictDecision?) -> Void
  private var applyToAll = false

  override func bodyHeight(_ innerWidth: Int) -> Int { wrap(path, innerWidth).count + 2 }

  override func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ innerWidth: Int) {
    let bg = background
    let lines = wrap(path, innerWidth)
    for i in 0..<lines.count {
      screen.text(x, y + i, lines[i], bg)
    }
    screen.text(
      x,
      y + lines.count + 1,
      "[\(applyToAll ? "x" : " ")] 残りすべてに適用",
      bg.copyWith(fg: applyToAll ? Palette.lime : Palette.muted)
    )
  }

  override var hints: [(String, String)] {
    [
      ("O", "上書き"),
      ("N", "別名で保存"),
      ("S", "スキップ"),
      ("A", "すべてに適用"),
      ("Esc", "中止"),
    ]
  }

  override func handleKey(_ key: Key) {
    if key.isLetter("a") || key.char == " " {
      applyToAll = !applyToAll
    } else if key.isLetter("o") {
      close(ConflictDecision(.overwrite, applyToAll: applyToAll))
    } else if key.isLetter("n") {
      close(ConflictDecision(.rename, applyToAll: applyToAll))
    } else if key.isLetter("s") {
      close(ConflictDecision(.skip, applyToAll: applyToAll))
    } else if key.name == "escape" {
      close(nil)
    }
  }
}

func askConflict(_ app: App, _ path: String) async -> ConflictDecision? {
  await app.showModal { (close: @escaping (ConflictDecision?) -> Void) in ConflictDialog(path, close) }
}

/// 名前を尋ねる。「/」を含む名前と [existing] にある名前は受け付けない。前後の空白は除く。空・キャンセルは null。
func askName(
  _ app: App,
  _ title: String,
  message: String? = nil,
  initial: String = "",
  selectStem: Bool = false,
  existing: Set<String> = []
) async -> String? {
  let input = await app.input(
    title,
    message: message,
    initial: initial,
    selectStem: selectStem,
    validate: { value in
      let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if name.contains("/") {
        return "「/」は使えません。"
      }
      if existing.contains(name) {
        return "同じ名前があります。"
      }
      return nil
    }
  )
  let name = input?.trimmingCharacters(in: .whitespacesAndNewlines)
  return name == nil || name!.isEmpty ? nil : name
}
