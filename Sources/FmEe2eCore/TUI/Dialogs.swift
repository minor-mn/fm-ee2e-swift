/// 表示幅 [width] で折り返す。
func wrap(_ text: String, _ width: Int) -> [String] {
  var lines: [String] = []
  for paragraph in text.components(separatedBy: "\n") {
    var line = ""
    var used = 0
    for cell in cells(paragraph) {
      let w = cellWidth(cell)
      if used + w > width {
        lines.append(line)
        line = ""
        used = 0
      }
      line += cell
      used += w
    }
    lines.append(line)
  }
  return lines
}

final class MessageDialog: Modal {
  init(_ title: String, _ message: String, _ close: @escaping (()) -> Void, accent: Rgb = Palette.purple, maxWidth: Int = 68) {
    self.message = message
    self.close = close
    self.maxWidth = maxWidth
    super.init(title, accent: accent)
  }

  let message: String
  let close: (()) -> Void

  /// 枠の最大の幅。
  let maxWidth: Int

  override func preferredWidth(_ screen: Screen) -> Int { min(screen.width - 4, maxWidth) }

  override func bodyHeight(_ innerWidth: Int) -> Int { wrap(message, innerWidth).count + 1 }

  override func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ innerWidth: Int) {
    let lines = wrap(message, innerWidth)
    // 画面に収まらない分は描かない（枠や案内に重ならないように）。
    for i in 0..<min(lines.count, max(bodyRows, 0)) {
      screen.text(x, y + i, lines[i], background)
    }
  }

  override var hints: [(String, String)] { [("Enter", tr("dialogs.hint.close"))] }

  override func handleKey(_ key: Key) {
    if key.name == "enter" || key.name == "escape" || key.char == " " {
      close(())
    }
  }
}

final class ConfirmDialog: Modal {
  init(
    _ title: String,
    _ message: String,
    _ yesLabel: String,
    _ close: @escaping (Bool) -> Void,
    accent: Rgb = Palette.purple,
    maxWidth: Int = 68,
    showHints: Bool = true
  ) {
    self.message = message
    self.yesLabel = yesLabel
    self.close = close
    self.maxWidth = maxWidth
    self.showHints = showHints
    super.init(title, accent: accent)
  }

  let message: String
  let yesLabel: String
  let close: (Bool) -> Void

  /// 枠の最大の幅。
  let maxWidth: Int

  /// 下の案内（Y / N）を出すか。本文にキーを書いたときは出さない。
  let showHints: Bool

  override func preferredWidth(_ screen: Screen) -> Int { min(screen.width - 4, maxWidth) }

  override func bodyHeight(_ innerWidth: Int) -> Int { wrap(message, innerWidth).count + (showHints ? 1 : 0) }

  override func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ innerWidth: Int) {
    let lines = wrap(message, innerWidth)
    // 画面に収まらない分は描かない（枠や案内に重ならないように）。
    for i in 0..<min(lines.count, max(bodyRows, 0)) {
      screen.text(x, y + i, lines[i], background)
    }
  }

  override var hints: [(String, String)] { showHints ? [("Y", yesLabel), ("N", tr("dialogs.cancel"))] : [] }

  override func handleKey(_ key: Key) {
    if key.isLetter("y") || key.name == "enter" {
      close(true)
    } else if key.isLetter("n") || key.name == "escape" {
      close(false)
    }
  }
}

/// 1行の入力欄。[selectStem] なら拡張子の前までを選択した状態で始め、入力で置き換える。
final class InputField {
  init(initial: String = "", masked: Bool = false, allowNewlines: Bool = false, selectStem: Bool = false) {
    self.masked = masked
    self.allowNewlines = allowNewlines
    original = initial
    cellList = cells(initial)
    cursor = cellList.count
    if selectStem {
      if let dot = initial.lastIndex(of: "."), dot != initial.startIndex {
        selectionEnd = cells(String(initial[..<dot])).count
      } else {
        selectionEnd = cellList.count
      }
      cursor = selectionEnd!
    }
  }

  let masked: Bool
  let allowNewlines: Bool
  private let original: String
  private var cellList: [String]
  private var cursor: Int

  /// 先頭から [selectionEnd] までが選択中。
  private var selectionEnd: Int?
  private var edited = false

  /// 編集していなければ元の文字列（macOSのNFDの名前を保つ）。
  var value: String { edited ? cellList.joined() : original }

  func clear() { set("") }

  /// 内容を [text] に置き換え、カーソルを末尾に置く。
  func set(_ text: String) { setAround(text, "") }

  var beforeCursor: String { cellList[0..<cursor].joined() }
  var afterCursor: String { cellList[cursor...].joined() }

  /// 内容を [before] + [after] にして、カーソルをその間に置く。
  func setAround(_ before: String, _ after: String) {
    let head = cells(before)
    cellList = head + cells(after)
    cursor = head.count
    selectionEnd = nil
    edited = true
  }

  private func deleteSelection() {
    if let end = selectionEnd {
      cellList.removeSubrange(0..<end)
      cursor = 0
      selectionEnd = nil
    }
  }

  private func insert(_ text: String) {
    deleteSelection()
    var inserted: [String] = []
    let lines = text.components(separatedBy: "\n")
    for (i, line) in lines.enumerated() {
      if i > 0 {
        inserted.append(allowNewlines ? "\n" : " ")
      }
      inserted.append(contentsOf: cells(line))
    }
    cellList.insert(contentsOf: inserted, at: cursor)
    cursor += inserted.count
    edited = true
  }

  /// 入力欄が処理したら true。
  @discardableResult
  func handleKey(_ key: Key) -> Bool {
    if let ch = key.char {
      insert(ch)
      return true
    }
    if let paste = key.paste {
      insert(paste)
      return true
    }
    switch key.name == "ctrl" ? "ctrl+\(key.ctrl!)" : key.name {
    case "left", "ctrl+b":
      selectionEnd = nil
      cursor = max(0, cursor - 1)
    case "right", "ctrl+f":
      selectionEnd = nil
      cursor = min(cellList.count, cursor + 1)
    case "home", "ctrl+a":
      selectionEnd = nil
      cursor = 0
    case "end", "ctrl+e":
      selectionEnd = nil
      cursor = cellList.count
    case "backspace", "ctrl+h":
      edited = true
      if selectionEnd != nil {
        deleteSelection()
      } else if cursor > 0 {
        cursor -= 1
        cellList.remove(at: cursor)
      }
    case "delete", "ctrl+d":
      edited = true
      if selectionEnd != nil {
        deleteSelection()
      } else if cursor < cellList.count {
        cellList.remove(at: cursor)
      }
    case "ctrl+u":
      edited = true
      selectionEnd = nil
      cellList.removeSubrange(0..<cursor)
      cursor = 0
    case "ctrl+k":
      edited = true
      selectionEnd = nil
      cellList.removeSubrange(cursor..<cellList.count)
    default:
      return false
    }
    return true
  }

  private func display(_ cell: String) -> String { masked ? "•" : (cell == "\n" ? "⏎" : cell) }

  /// 幅 [width] に描き、端末のカーソルを置く。
  func draw(_ screen: Screen, _ x: Int, _ y: Int, _ width: Int, focused: Bool = true) {
    let style = Style(bg: Palette.background)
    screen.fill(x, y, width, 1, style)
    let shown = cellList.map(display)
    // カーソルが見える範囲だけを描く。
    var start = 0
    while start < cursor && textWidth(shown[start..<cursor].joined()) > width - 1 {
      start += 1
    }
    var col = x
    for i in start..<shown.count {
      let w = textWidth(shown[i])
      if col + w > x + width {
        break
      }
      let selected = selectionEnd != nil && i < selectionEnd!
      col += screen.text(col, y, shown[i], selected ? style.copyWith(bg: Palette.selected) : style)
    }
    if focused {
      screen.cursor = (x + textWidth(shown[start..<cursor].joined()), y)
    }
  }
}

/// Tab の補完。カーソル前の文字列を受け取り、新しいカーソル前の文字列と、補完しきれないときの候補を返す。
typealias Completer = (String) async throws -> (String, [String])?

final class InputDialog: Modal {
  init(
    _ title: String,
    _ close: @escaping (String?) -> Void,
    message: String? = nil,
    initial: String = "",
    masked: Bool = false,
    allowNewlines: Bool = false,
    selectStem: Bool = false,
    validate: ((String) -> String?)? = nil,
    history: [String] = [],
    complete: Completer? = nil,
    onChange: (() -> Void)? = nil,
    accent: Rgb = Palette.purple
  ) {
    self.close = close
    self.message = message
    self.validate = validate
    self.history = history
    self.complete = complete
    self.onChange = onChange
    field = InputField(initial: initial, masked: masked, allowNewlines: allowNewlines, selectStem: selectStem)
    historyIndex = history.count
    super.init(title, accent: accent)
  }

  /// Tab の補完。時間がかかってもよい（接続先に問い合わせるときなど）。
  let complete: Completer?

  /// 補完が終わって表示が変わったとき（描き直す）。
  let onChange: (() -> Void)?

  /// 前回の Tab で補完しきれなかったときの候補。
  private var candidates: [String] = []
  private static let maxCandidateLines = 6

  let message: String?
  let field: InputField

  /// ↑↓ でたどる入力の履歴（古い順）。readline の history-search-backward / forward と同じく、
  /// カーソルより前の文字列で始まるものだけをたどる。
  let history: [String]
  private var historyIndex: Int

  /// たどっている最中の検索文字列。ほかのキーを押すと nil に戻り、次の ↑↓ でその時点の文字列から探し直す。
  private var searchPrefix: String?

  /// 履歴をたどる前に入力していた文字列。
  private var draft = ""

  /// エラーの文言を返すと閉じずに表示する。
  let validate: ((String) -> String?)?
  let close: (String?) -> Void
  private var error: String?

  private func messageLines(_ width: Int) -> [String] { message.map { wrap($0, width) } ?? [] }

  /// 候補を幅に詰めて並べた行。収まらない分は「…ほかN件」にする。
  private func candidateLines(_ width: Int) -> [String] {
    var lines: [String] = []
    var line = ""
    for (i, item) in candidates.enumerated() {
      let next = line.isEmpty ? item : "\(line)  \(item)"
      if textWidth(next) <= width || line.isEmpty {
        line = next
        continue
      }
      lines.append(line)
      line = item
      if lines.count == Self.maxCandidateLines - 1 {
        let rest = candidates.count - i
        lines.append(truncate("\(item)  " + tr("dialogs.more_candidates", ["count": rest - 1]), width))
        return lines
      }
    }
    if !line.isEmpty {
      lines.append(truncate(line, width))
    }
    return lines
  }

  override func bodyHeight(_ innerWidth: Int) -> Int {
    messageLines(innerWidth).count + 2 + (error == nil ? 0 : 1) + candidateLines(innerWidth).count
  }

  override func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ innerWidth: Int) {
    let lines = messageLines(innerWidth)
    for (i, line) in lines.enumerated() {
      screen.text(x, y + i, line, background.copyWith(fg: Palette.muted))
    }
    var row = y + lines.count
    field.draw(screen, x, row, innerWidth)
    row += 1
    if let error {
      screen.text(x, row, truncate(error, innerWidth), background.copyWith(fg: Palette.error))
      row += 1
    }
    for line in candidateLines(innerWidth) {
      screen.text(x, row, line, background.copyWith(fg: Palette.muted))
      row += 1
    }
  }

  override var hints: [(String, String)] {
    var list: [(String, String)] = []
    if complete != nil { list.append(("Tab", tr("dialogs.hint.complete"))) }
    if !history.isEmpty { list.append(("↑↓", tr("dialogs.hint.history"))) }
    list.append(("Enter", tr("dialogs.hint.decide")))
    list.append(("Esc", tr("dialogs.cancel")))
    return list
  }

  override func handleKey(_ key: Key) {
    if key.name == "escape" {
      close(nil)
      return
    }
    if key.name == "enter" {
      let value = field.value
      if let error = validate?(value) {
        self.error = error
      } else {
        close(value)
      }
      return
    }
    if key.name == "tab", let complete {
      let before = field.beforeCursor
      let after = field.afterCursor
      Task {
        guard let result = try? await complete(before) else { return }
        // 補完を待つ間に入力が変わっていれば使わない。
        if field.beforeCursor != before || field.afterCursor != after {
          return
        }
        field.setAround(result.0, after)
        candidates = result.1
        onChange?()
      }
      return
    }
    candidates = []
    if (key.name == "up" || key.name == "down") && !history.isEmpty {
      searchHistory(up: key.name == "up")
      return
    }
    searchPrefix = nil
    if field.handleKey(key) {
      error = nil
    }
  }

  /// [up] なら古い方、でなければ新しい方へ、検索文字列で始まる履歴を探して表示する。
  /// 新しい方に見つからなければ、たどる前の入力に戻す。カーソルは検索文字列の直後（空なら末尾）に置く。
  private func searchHistory(up: Bool) {
    let prefix: String
    if let searchPrefix {
      prefix = searchPrefix
    } else {
      draft = field.value
      historyIndex = history.count
      prefix = field.beforeCursor
      searchPrefix = prefix
    }
    var i = historyIndex
    while true {
      i += up ? -1 : 1
      if i < 0 {
        return
      }
      if i >= history.count {
        historyIndex = history.count
        field.setAround(prefix, String(draft.dropFirst(prefix.count)))
        return
      }
      if history[i].hasPrefix(prefix) && history[i] != field.value {
        break
      }
    }
    historyIndex = i
    if prefix.isEmpty {
      field.set(history[i])
    } else {
      field.setAround(prefix, String(history[i].dropFirst(prefix.count)))
    }
  }
}

/// 実行ファイルに渡す引数の入力。Tab で入力欄・実行・キャンセルを移動する。
final class ExecDialog: Modal {
  init(_ name: String, _ directory: String, _ close: @escaping (String?) -> Void) {
    self.name = name
    self.directory = directory
    self.close = close
    super.init(tr("dialogs.exec.title"))
  }

  let name: String
  let directory: String
  let close: (String?) -> Void
  let field = InputField()

  /// 0: 入力欄、1: 実行、2: キャンセル。
  private var focus = 0

  private static var buttons: [String] { ["exec", tr("dialogs.cancel")] }

  override func bodyHeight(_ innerWidth: Int) -> Int { 5 }

  override func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ innerWidth: Int) {
    screen.text(x, y, truncate(name, innerWidth), background.copyWith(bold: true))
    screen.text(x, y + 1, truncateLeft("in \(directory)", innerWidth), background.copyWith(fg: Palette.muted))
    screen.text(x, y + 2, tr("dialogs.exec.arguments"), background.copyWith(fg: Palette.muted))
    field.draw(screen, x + 5, y + 2, innerWidth - 5, focused: focus == 0)
    var col = x + innerWidth
    for i in stride(from: Self.buttons.count - 1, through: 0, by: -1) {
      let label = " \(Self.buttons[i]) "
      col -= textWidth(label)
      let focused = focus == i + 1
      screen.text(
        col, y + 4, label,
        focused
          ? background.copyWith(fg: Palette.background, bg: Palette.lime, bold: true)
          : background.copyWith(bg: Palette.outline)
      )
      col -= 2
    }
  }

  override var hints: [(String, String)] { [("Tab", tr("dialogs.hint.move")), ("Enter", tr("dialogs.hint.decide")), ("Esc", tr("dialogs.cancel"))] }

  override func handleKey(_ key: Key) {
    switch key.name {
    case "escape":
      close(nil)
    case "tab":
      focus = (focus + 1) % 3
    case "backTab":
      focus = (focus + 2) % 3
    case "enter":
      close(focus == 2 ? nil : field.value)
    default:
      if focus == 0 {
        field.handleKey(key)
      } else if key.name == "left" {
        focus = 1
      } else if key.name == "right" {
        focus = 2
      }
    }
  }
}

/// パーミッションの変更。所有者・グループ・その他の rwx に加え、ディレクトリならスティッキービット、
/// ファイルなら SUID・SGID を切り替えられる。結果は下位12ビット。
final class ModeDialog: Modal {
  init(_ label: String, _ mode: Int, _ close: @escaping (Int?) -> Void, isDir: Bool) {
    self.label = label
    self.close = close
    bits = mode & 0xfff
    special = isDir ? [(0x200, "Sticky")] : [(0x800, "SUID"), (0x400, "SGID")]
    super.init(tr("dialogs.mode.title"))
  }

  let label: String
  let close: (Int?) -> Void

  /// 切り替えられる特殊ビットと、その名前。
  let special: [(Int, String)]
  private var bits: Int
  private var row = 0
  private var col = 0

  private static var rows: [String] {
    [tr("dialogs.mode.owner"), tr("dialogs.mode.group"), tr("dialogs.mode.other"), tr("dialogs.mode.special")]
  }
  private static var cols: [String] { [tr("dialogs.mode.read"), tr("dialogs.mode.write"), tr("dialogs.mode.execute")] }
  private static let labelWidth = 10

  private func bit(_ row: Int, _ col: Int) -> Int { row == 3 ? special[col].0 : 1 << (8 - row * 3 - col) }

  private func colCount(_ row: Int) -> Int { row == 3 ? special.count : 3 }

  /// ls -l と同じ表記（SUID・SGID は s/S、スティッキービットは t/T）。
  static func symbolic(_ bits: Int) -> String {
    let rwx = Array("rwx")
    var chars: [Character] = (0...8).map { i in
      let shift = 8 - i
      return (bits >> shift) & 1 == 1 ? rwx[i % 3] : "-"
    }
    for (index, flag, letter) in [(2, 0x800, "s"), (5, 0x400, "s"), (8, 0x200, "t")] where bits & flag != 0 {
      chars[index] = Character(chars[index] == "x" ? letter : letter.uppercased())
    }
    return String(chars)
  }

  override func bodyHeight(_ innerWidth: Int) -> Int { 8 }

  private func drawCheck(_ screen: Screen, _ x: Int, _ y: Int, _ row: Int, _ col: Int) {
    let on = bits & bit(row, col) != 0
    screen.text(
      x, y, on ? "[x]" : "[ ]",
      background.copyWith(
        fg: on ? Palette.lime : Palette.muted,
        bg: row == self.row && col == self.col ? Palette.selected : Palette.surfaceHigh,
        bold: on
      )
    )
  }

  override func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ innerWidth: Int) {
    screen.text(x, y, truncate(label, innerWidth), background.copyWith(bold: true))
    for c in 0..<Self.cols.count {
      screen.text(x + Self.labelWidth + c * 7, y + 2, Self.cols[c], background.copyWith(fg: Palette.muted))
    }
    for r in 0..<3 {
      screen.text(x, y + 3 + r, Self.rows[r], background.copyWith(fg: Palette.muted))
      for c in 0..<Self.cols.count {
        drawCheck(screen, x + Self.labelWidth + c * 7, y + 3 + r, r, c)
      }
    }
    screen.text(x, y + 7, Self.rows[3], background.copyWith(fg: Palette.muted))
    var column = x + Self.labelWidth
    for c in 0..<special.count {
      drawCheck(screen, column, y + 7, 3, c)
      column += 4 + screen.text(column + 4, y + 7, special[c].1, background.copyWith(fg: Palette.muted)) + 3
    }
    let digits = String(bits, radix: 8)
    let octal = String(repeating: "0", count: max(0, (bits > 0x1ff ? 4 : 3) - digits.count)) + digits
    screen.text(x + Self.labelWidth + 3 * 7, y + 4, "\(octal)  \(Self.symbolic(bits))", background.copyWith(fg: Palette.text, bold: true))
  }

  override var hints: [(String, String)] { [("←↑↓→", tr("dialogs.hint.move")), ("Space", tr("dialogs.hint.toggle")), ("Enter", tr("dialogs.hint.apply")), ("Esc", tr("dialogs.cancel"))] }

  override func handleKey(_ key: Key) {
    switch key.name {
    case "escape":
      close(nil)
    case "enter":
      close(bits)
    case "up":
      row = (row + 3) % 4
    case "down":
      row = (row + 1) % 4
    case "left":
      col = (col + colCount(row) - 1) % colCount(row)
    case "right", "tab":
      col = (col + 1) % colCount(row)
    case "char" where key.char == " ":
      bits ^= bit(row, col)
    default:
      break
    }
    col = min(max(col, 0), colCount(row) - 1)
  }
}

/// 選択肢から1つ選ぶ小窓。↑↓ で選び、Enter で決める。空文字の選択肢は区切りの空行で、選べない。
/// 画面に収まらなければページに分け、←→ でページを移る。
final class ChoiceDialog: Modal {
  init(
    _ title: String,
    _ options: [String],
    _ close: @escaping (Int?) -> Void,
    note: String? = nil,
    closeKey: ((Key) -> Bool)? = nil,
    closeAtEdges: Bool = false
  ) {
    self.options = options
    self.close = close
    self.note = note
    self.closeKey = closeKey
    self.closeAtEdges = closeAtEdges
    index = options.firstIndex { !$0.isEmpty } ?? -1
    pageSize = options.count
    super.init(title)
  }

  let options: [String]
  let close: (Int?) -> Void

  /// Esc のほかに、小窓を閉じるキー（開いたキーをもう一度押すと閉じる、など）。
  let closeKey: ((Key) -> Bool)?

  /// 一番上で ↑、一番下で ↓ を押したら、反対の端に回らずに閉じる。
  let closeAtEdges: Bool

  /// 選択肢の下に出す注意書き。
  let note: String?
  private var index: Int

  /// 1ページに出す選択肢の数。前回描いたときの値。
  private var pageSize: Int

  private var pages: Int { (options.count + pageSize - 1) / max(pageSize, 1) }
  private var page: Int { index / max(pageSize, 1) }

  /// 1ページの選択肢の数。本文の [rows] 行から、選択肢のほかの行（注意書きなど）を除いた分。
  private func fit(_ rows: Int, _ innerWidth: Int) -> Int {
    max(1, min(options.count, rows - (bodyHeight(innerWidth) - options.count)))
  }

  /// 幅は、選択肢・見出し・注意書きのほか、キーの案内とページ番号も収まるように取る。
  override func preferredWidth(_ screen: Screen) -> Int {
    let width = max(note == nil ? 0 : 64, max(textWidth(title) + 8, options.map(textWidth).max(by: <).map { $0 + 8 } ?? 8))
    // 枠の上下・空行・案内の4行を除いた高さで、ページに分けるかを決める（drawBody で描くときも同じ数になる）。
    pageSize = fit(screen.height - 2 - 4, width - 4)
    let hintsWidth = hints.reduce(0) { $0 + textWidth($1.0) + textWidth($1.1) + 2 }
    let statusWidth = status.map { textWidth($0.0) + 1 } ?? 0
    return min(screen.width - 4, max(width, hintsWidth + statusWidth + 4))
  }

  private func noteLines(_ innerWidth: Int) -> [String] { note.map { wrap($0, innerWidth - 1) } ?? [] }

  override func bodyHeight(_ innerWidth: Int) -> Int {
    options.count + 1 + (note == nil ? 0 : noteLines(innerWidth).count + 1)
  }

  override func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ innerWidth: Int) {
    pageSize = fit(bodyRows, innerWidth)
    let first = page * pageSize
    let shown = min(pageSize, options.count - first)
    for row in 0..<max(shown, 0) {
      let i = first + row
      if options[i].isEmpty {
        continue
      }
      let selected = i == index
      let style = background.copyWith(bg: selected ? Palette.selected : Palette.surfaceHigh, bold: selected)
      screen.fill(x, y + row, innerWidth, 1, style)
      screen.text(x + 1, y + row, truncate(options[i], innerWidth - 1), style)
    }
    for (i, line) in noteLines(innerWidth).enumerated() {
      screen.text(x + 1, y + pageSize + 1 + i, line, background.copyWith(fg: Palette.muted))
    }
  }

  override var hints: [(String, String)] {
    var list: [(String, String)] = [("↑↓", tr("dialogs.hint.select"))]
    if pages > 1 { list.append(("←→", tr("dialogs.hint.page"))) }
    list.append(("Enter", tr("dialogs.hint.decide")))
    list.append(("Esc", tr("dialogs.cancel")))
    return list
  }

  override var status: (String, Rgb)? { pages > 1 ? ("\(page + 1)/\(pages)", Palette.muted) : nil }

  /// [from] から [step] ずつ進んで、最初の選べる選択肢（区切りの空行を飛ばす）。
  private func selectable(_ from: Int, _ step: Int) -> Int {
    let n = options.count
    var i = ((from % n) + n) % n
    while options[i].isEmpty {
      i = ((i + step) % n + n) % n
    }
    return i
  }

  /// [page] ページ目の、最初の選べる選択肢へ移る。
  private func toPage(_ page: Int) {
    let first = min(max(page, 0), pages - 1) * pageSize
    if let i = options.indices.first(where: { $0 >= first && !options[$0].isEmpty }) {
      index = i
    } else {
      index = selectable(first, -1)
    }
  }

  override func handleKey(_ key: Key) {
    if closeKey?(key) ?? false {
      close(nil)
      return
    }
    switch key.name {
    case "escape":
      close(nil)
    case "enter":
      close(index)
    case "up" where closeAtEdges && index == 0:
      close(nil)
    case "down" where closeAtEdges && index == options.count - 1:
      close(nil)
    case "up":
      index = selectable(index - 1, -1)
    case "down", "tab":
      index = selectable(index + 1, 1)
    case "left" where pages > 1:
      toPage(page - 1)
    case "right" where pages > 1:
      toPage(page + 1)
    default:
      break
    }
  }
}

/// 処理中の表示。キーは受け付けない。
final class ProgressDialog: Modal {
  init(_ message: String, onEscape: (() -> Void)? = nil) {
    self.message = message
    self.onEscape = onEscape
    super.init(tr("dialogs.progress_title"), accent: Palette.green)
  }

  /// Esc を押したとき（中断）。nil なら Esc は効かない。
  let onEscape: (() -> Void)?

  /// 出している文言。処理の途中で変えてよい（[withProgress] の update）。
  var message: String

  override func preferredWidth(_ screen: Screen) -> Int { min(screen.width - 4, max(30, textWidth(message) + 6)) }

  override func bodyHeight(_ innerWidth: Int) -> Int { 1 }

  override func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ innerWidth: Int) {
    screen.text(x, y, message, background)
  }

  override var hints: [(String, String)] { onEscape == nil ? [] : [("Esc", tr("dialogs.hint.abort"))] }

  override func handleKey(_ key: Key) {
    if key.name == "escape" {
      onEscape?()
    }
  }
}

extension App {
  func showMessage(_ title: String, _ message: String, maxWidth: Int = 68) async {
    await showModal { (close: @escaping (()) -> Void) in MessageDialog(title, message, close, maxWidth: maxWidth) }
  }

  /// エラーを出す。文言（String）でも Error でもよい。
  func showError(_ error: Any) async {
    let message = (error as? any Error).map(errorMessage) ?? "\(error)"
    await showModal { (close: @escaping (()) -> Void) in MessageDialog(tr("dialogs.error_title"), message, close, accent: Palette.error) }
  }

  func confirm(_ title: String, _ message: String, yes: String = tr("dialogs.yes"), maxWidth: Int = 68, showHints: Bool = true) async -> Bool {
    await showModal { close in ConfirmDialog(title, message, yes, close, maxWidth: maxWidth, showHints: showHints) }
  }

  func input(
    _ title: String,
    message: String? = nil,
    initial: String = "",
    masked: Bool = false,
    allowNewlines: Bool = false,
    selectStem: Bool = false,
    validate: ((String) -> String?)? = nil,
    history: [String] = [],
    complete: Completer? = nil
  ) async -> String? {
    await showModal { close in
      InputDialog(
        title, close,
        message: message,
        initial: initial,
        masked: masked,
        allowNewlines: allowNewlines,
        selectStem: selectStem,
        validate: validate,
        history: history,
        complete: complete,
        onChange: { [unowned self] in requestRender() }
      )
    }
  }

  /// [options] から1つ選ばせ、その番号を返す。キャンセルなら nil。
  func askChoice(
    _ title: String,
    _ options: [String],
    note: String? = nil,
    closeKey: ((Key) -> Bool)? = nil,
    closeAtEdges: Bool = false
  ) async -> Int? {
    await showModal { close in ChoiceDialog(title, options, close, note: note, closeKey: closeKey, closeAtEdges: closeAtEdges) }
  }

  /// パーミッションを聞く。キャンセルなら nil。
  func askMode(_ label: String, _ mode: Int, isDir: Bool) async -> Int? {
    await showModal { close in ModeDialog(label, mode, close, isDir: isDir) }
  }

  /// 実行ファイルの引数を聞く。キャンセルなら nil。
  func askExecArgs(_ name: String, _ directory: String) async -> String? {
    await showModal { close in ExecDialog(name, directory, close) }
  }

  /// [action] の間「処理中」を表示する。途中で別のダイアログ（同名確認など）を重ねてよい。
  func withProgress<T>(_ message: String, _ action: () async throws -> T) async rethrows -> T {
    try await withUpdatingProgress(message) { _ in try await action() }
  }

  /// [withProgress] と同じく「処理中」を表示し、[action] に渡す update で文言を変えられる（「3/5 件目」など）。
  /// [onEscape] を渡すと、Esc で呼ぶ（[action] を止めるのは呼ばれた側）。
  func withUpdatingProgress<T>(
    _ message: String,
    onEscape: (() -> Void)? = nil,
    _ action: (_ update: @escaping (String) -> Void) async throws -> T
  ) async rethrows -> T {
    let dialog = ProgressDialog(message, onEscape: onEscape)
    let close = openModal(dialog)
    defer {
      close()
    }
    return try await action { [unowned self] next in
      dialog.message = next
      requestRender()
    }
  }
}
