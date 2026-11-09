// メイン画面の上下の帯。上は枠で囲んだ4行（タイトル入りの線、容量、所有者、下の線）、
// 下はマーク・案内・ファンクションキーの行。

import Foundation

/// アプリのバージョン（.app の Info.plist の CFBundleShortVersionString。make-app.sh が git のタグから入れる）。
/// .app の外から動かしたとき（.build/debug/fm-ee2e など）は nil。
private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

/// FD のように上の帯を枠で囲み、上の線にタイトルを埋め込む。バージョンがわかれば、タイトルの右に添える。
func drawHeader(_ screen: Screen) {
  let bg = Style()
  screen.box(0, 0, screen.width, 4, bg.copyWith(fg: Palette.outline))
  var titleEnd = 3 + screen.gradientText(3, 0, "fm-ee2e-swift", [Palette.purple, Palette.green], bg.copyWith(bold: true))
  if let appVersion {
    titleEnd += screen.text(titleEnd, 0, " v\(appVersion)", bg.copyWith(fg: Rgb(0x666666)))
  }
  screen.text(2, 0, " ", bg)
  screen.text(titleEnd, 0, " ", bg)
}

/// [pane] のドライブの Total / Used / Free。[Pane.headerText] があれば、その代わりにそれを出す（git のリポジトリ名など）。
func drawUsage(_ screen: Screen, _ y: Int, _ pane: Pane) {
  let bg = Style()
  let usage = pane.usage
  var x = 2
  x += screen.text(x, y, pane.title, bg.copyWith(fg: pane.accent, bold: true))
  if let fields = pane.headerFields {
    drawFields(screen, x + 3, y, fields.first ?? [])
    return
  }
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
  if let fields = pane.headerFields {
    if fields.count > 1 { drawFields(screen, 2, y, fields[1]) }
    return
  }
  guard let entry = pane.current, pane.placeholder == nil, let ownership = pane.ownershipOf(entry) else {
    return
  }
  var x = 2
  var valueEnd = x
  for (label, value) in [("Owner", ownership.owner), ("Group", ownership.group), ("Mode", ownership.permissions)] {
    x += screen.text(x, y, label, bg.copyWith(fg: Palette.muted))
    valueEnd = x + 1 + screen.text(x + 1, y, value, bg)
    x = valueEnd + 3
  }
  // シンボリックリンクなら、Mode の右に1マス空けて指している先を出す。
  if let link = ownership.linkTarget {
    let room = screen.width - 2 - (valueEnd + 1)
    if room > 0 {
      screen.text(valueEnd + 1, y, truncate(link, room), bg, maxWidth: room)
    }
  }
}

/// 名前（薄い色）と値を、所有者の行と同じ間隔で並べる。帯の右端を越える分は省く。
private func drawFields(_ screen: Screen, _ start: Int, _ y: Int, _ fields: [(String, String)]) {
  let bg = Style()
  let end = screen.width - 2
  var x = start
  for (label, value) in fields {
    guard x < end else { break }
    x += screen.text(x, y, truncate(label, end - x), bg.copyWith(fg: Palette.muted), maxWidth: end - x)
    guard x + 1 < end else { break }
    x += screen.text(x + 1, y, truncate(value, end - x - 1), bg, maxWidth: end - x - 1) + 4
  }
}

/// [pane] のマークの数とファイルの合計サイズ（ほかのフォルダーの分も含む）。[side] は「左」か「右」。
func drawMarks(_ screen: Screen, _ y: Int, _ pane: Pane, _ side: String) {
  let marks = pane.marks.values
  if let container = pane as? ContainerPane, container.ssh == nil {
    screen.text(1, y, truncate(tr("container.mark_count", ["side": side, "count": marks.count]), screen.width - 2), Style(fg: Palette.lime, bold: true))
    return
  }
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

/// F1〜F12 の機能と、同じ動きのキーの名前（文字は「char:小文字」、Ctrl は「ctrl:文字」。nil は割り当てなし）。
/// F11 は macOS がデスクトップの表示に使うので空ける。F12 は右の窓によって変わるので、[drawFunctionKeys] に渡す。
let functionKeys: [(String, String)?] = [
  ("Attr", "char:a"),
  ("Copy", "char:c"),
  ("Move", "char:m"),
  ("Delete", "char:d"),
  ("Touch", "char:t"),
  ("Mkdir", "char:k"),
  ("Rename", "char:r"),
  ("Edit", "char:e"),
  ("Format", "char:f"),
  ("TileView", "ctrl:t"),
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
      // 文字キーのないもの（Container の F12 など）は、どこも強めない。
      if let char = key.first, let at = Array(label.uppercased()).firstIndex(of: char), pad + at < slot {
        screen.text(x + pad + at, y, String(letters[at]), keyStyle)
      }
    }
    x += slot
  }
}
