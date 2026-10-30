// メイン画面の上下の帯。上は枠で囲んだ4行（タイトル入りの線、容量、所有者、下の線）、
// 下はマーク・案内・ファンクションキーの行。

/// FD のように上の帯を枠で囲み、上の線にタイトルを埋め込む。
func drawHeader(_ screen: Screen) {
  let bg = Style()
  screen.box(0, 0, screen.width, 4, bg.copyWith(fg: Palette.outline))
  let titleEnd = 3 + screen.gradientText(3, 0, "fm-ee2e-swift", [Palette.purple, Palette.green], bg.copyWith(bold: true))
  screen.text(2, 0, " ", bg)
  screen.text(titleEnd, 0, " ", bg)
}

/// [pane] のドライブの Total / Used / Free。[Pane.headerText] があれば、その代わりにそれを出す（git のリポジトリ名など）。
func drawUsage(_ screen: Screen, _ y: Int, _ pane: Pane) {
  let bg = Style()
  let usage = pane.usage
  var x = 2
  x += screen.text(x, y, pane.title, bg.copyWith(fg: pane.accent, bold: true))
  if let text = pane.headerText {
    screen.text(x + 3, y, truncate(text, max(0, screen.width - x - 5)), bg.copyWith(fg: Palette.muted, bold: true))
    return
  }
  func bytes(_ value: Int?) -> String { value.map(formatBytes) ?? "—" }
  let all = [("Total", bytes(usage?.total)), ("Used", bytes(usage?.used)), ("Free", bytes(usage?.free))]
  for (label, value) in all where pane.usageLabels.contains(label) {
    x += 3
    x += screen.text(x, y, label, bg.copyWith(fg: Palette.muted))
    x += screen.text(x + 1, y, value, bg) + 1
  }
}

/// [pane] のカーソル位置の項目の所有者・グループ・パーミッション。
func drawOwnership(_ screen: Screen, _ y: Int, _ pane: Pane) {
  let bg = Style()
  guard let entry = pane.current, pane.placeholder == nil, let ownership = pane.ownershipOf(entry) else {
    return
  }
  var x = 2
  for (label, value) in [("Owner", ownership.owner), ("Group", ownership.group), ("Mode", ownership.permissions)] {
    x += screen.text(x, y, label, bg.copyWith(fg: Palette.muted))
    x += screen.text(x + 1, y, value, bg) + 4
  }
}

/// [pane] のマークの数とファイルの合計サイズ（ほかのフォルダーの分も含む）。[side] は「左」か「右」。
func drawMarks(_ screen: Screen, _ y: Int, _ pane: Pane, _ side: String) {
  let marks = pane.marks.values
  let bytes = marks.reduce(0) { $0 + ($1.entry.size ?? 0) }
  let elsewhere = pane.marksElsewhere
  var parts = [tr("status_bars.marks", ["side": side, "count": marks.count, "size": formatBytes(bytes)])]
  if elsewhere > 0 {
    parts.append(tr("status_bars.marks_elsewhere", ["count": elsewhere]))
  }
  screen.text(1, y, truncate(parts.joined(separator: "  "), screen.width - 2), Style(fg: Palette.lime, bold: true))
}

/// ファンクションキーに割り当てのない文字キーの案内（[keys]）と、右端に [note]。
func drawKeyHints(_ screen: Screen, _ y: Int, _ keys: [(String, String)], note: String? = nil) {
  let bg = Style()
  var x = 1
  for (key, label) in keys {
    x += screen.text(x, y, key, bg.copyWith(fg: Palette.lime, bold: true))
    x += screen.text(x, y, ":\(label)", bg.copyWith(fg: Palette.muted)) + 1
  }
  if let note {
    screen.text(screen.width - 1 - textWidth(note), y, note, bg.copyWith(fg: Palette.lime))
  }
}

/// F1〜F12 の機能と、同じ動きの文字キー（nil は割り当てなし）。F11 は macOS がデスクトップの表示に使うので空ける。
/// F12 は右の窓によって変わるので、[drawFunctionKeys] に渡す。
let functionKeys: [(String, String)?] = [
  ("Attr", "A"),
  ("Copy", "C"),
  ("Move", "M"),
  ("Delete", "D"),
  ("Touch", "T"),
  ("Mkdir", "K"),
  ("Rename", "R"),
  ("Edit", "E"),
  nil,
  nil,
  nil,
]

/// FD のように、最下段に F1〜F12 の機能（[keys]、nil は空き）を、キーボードと同じく4つずつの組にして並べる。
func drawFunctionKeys(_ screen: Screen, _ y: Int, _ keys: [(String, String)?]) {
  // 組の間は2桁、キーの間は1桁空ける。
  let slot = (screen.width - 2 * 2 - 9) / 12
  if slot < 2 {
    return
  }
  let style = Style(fg: Palette.background, bg: Palette.lime, bold: true)
  // ヘルプを兼ねて、同じ動きの文字キーに当たる文字を緑の強い黄緑の地にする。
  let keyStyle = Style(fg: Palette.background, bg: Palette.yellowGreen, bold: true)
  var x = (screen.width - (slot * 12 + 2 * 2 + 9)) / 2
  for i in 0..<keys.count {
    if i > 0 {
      x += i % 4 == 0 ? 2 : 1
    }
    screen.fill(x, y, slot, 1, style)
    if let (label, key) = keys[i] {
      // 中央寄せ。収まらなければ右を切る。
      let pad = max(0, slot - textWidth(label)) / 2
      screen.text(x + pad, y, label, style, maxWidth: slot - pad)
      // ラベルは ASCII なので、文字の位置はそのまま桁になる。
      let letters = Array(label)
      if let at = Array(label.uppercased()).firstIndex(of: Character(key)), pad + at < slot {
        screen.text(x + pad + at, y, String(letters[at]), keyStyle)
      }
    }
    x += slot
  }
}
