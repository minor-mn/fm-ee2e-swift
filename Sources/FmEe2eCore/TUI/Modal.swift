/// モーダルの置き方。
enum ModalFrame {
  /// 画面の中央の、枠で囲んだ小窓。高さは本文に合わせる。
  case dialog

  /// 左右の窓の場所（上下の帯の間）を覆う、枠で囲んだ窓。
  case panel

  /// 画面全体。上の帯に見出し、下の帯に案内。
  case page
}

/// ダイアログや全画面の表示など、画面の上に重ねるものの共通部分。
/// 枠・見出し・案内は [frame] に合わせてここで描き、本文だけを [drawBody] で描く。
/// 継承して使う（Dart の abstract class Modal）。
class Modal: View {
  init(_ title: String, accent: Rgb = Palette.purple) {
    self.title = title
    self.accent = accent
  }

  let title: String

  /// 枠と見出しの色。
  let accent: Rgb

  var frame: ModalFrame { .dialog }

  /// 見出しの色。
  var titleColor: Rgb { accent }

  /// 本文の地。
  var background: Style {
    switch frame {
    case .dialog: Style(bg: Palette.surfaceHigh)
    case .panel: Style(bg: Palette.surface)
    case .page: Style()
    }
  }

  /// [ModalFrame.page] の上下の帯の地。
  static let bar = Style(bg: Palette.surfaceHigh)

  /// 下に出すキーの案内。
  var hints: [(String, String)] { [] }

  /// 案内の行の右端に出す状態と、その色（終了コードなど）。出さなければ nil。
  var status: (String, Rgb)? { nil }

  /// [ModalFrame.dialog] の枠の幅。
  func preferredWidth(_ screen: Screen) -> Int { min(screen.width - 4, 68) }

  /// [ModalFrame.dialog] の本文の行数（枠と案内を除く）。
  func bodyHeight(_ innerWidth: Int) -> Int { 0 }

  /// 本文に使える行数。前回描いたときの値（PgUp・PgDn の幅などに使う）。
  var bodyRows = 0

  /// 本文を [x]・[y] から幅 [width]、[bodyRows] 行に描く。
  func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ width: Int) {}

  /// [ModalFrame.page] の上の帯の見出し。
  func drawTitle(_ screen: Screen, _ x: Int, _ y: Int, _ width: Int) {
    screen.text(x, y, truncate(title, width), Modal.bar.copyWith(fg: titleColor, bold: true))
  }

  func handleKey(_ key: Key) {}

  func draw(_ screen: Screen) {
    switch frame {
    case .dialog:
      let w = max(20, preferredWidth(screen))
      let inner = w - 4
      // 枠の上下に加え、案内があれば本文との間の1行と案内の1行。
      let extra = hints.isEmpty ? 2 : 4
      let h = min(screen.height - 2, bodyHeight(inner) + extra)
      drawBox(screen, (screen.width - w) / 2, max(0, (screen.height - h) / 2), w, h, extra)
    case .panel:
      // 上の帯の下から、下の帯（マーク・案内・ファンクションキー）の上まで。
      drawBox(screen, 0, 1, screen.width, max(8, screen.height - 3), hints.isEmpty ? 2 : 3)
    case .page:
      let w = screen.width
      let h = screen.height
      screen.fill(0, 0, w, h, background)
      screen.fill(0, 0, w, 1, Modal.bar)
      drawTitle(screen, 1, 0, w - 2)
      bodyRows = max(1, h - 2)
      drawBody(screen, 0, 1, w)
      screen.fill(0, h - 1, w, 1, Modal.bar)
      drawHints(screen, 1, h - 1, hints, Modal.bar, maxWidth: w - 2)
      drawStatus(screen, w - 1, h - 1, Modal.bar)
    }
  }

  /// 枠で囲んだ窓。本文は枠の内側に2桁空けて描き、案内は枠の下の線の1行上に出す。
  private func drawBox(_ screen: Screen, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ extra: Int) {
    let inner = w - 4
    bodyRows = h - extra
    screen.fill(x, y, w, h, background)
    screen.box(
      x, y, w, h, background.copyWith(fg: accent),
      title: title,
      titleStyle: background.copyWith(fg: titleColor, bold: true)
    )
    drawBody(screen, x + 2, y + 1, inner)
    if !hints.isEmpty {
      drawHints(screen, x + 2, y + h - 2, hints, background, maxWidth: inner)
    }
    drawStatus(screen, x + w - 2, y + h - 2, background)
  }

  /// [status] を、[right] の桁の手前で終わるように出す。
  private func drawStatus(_ screen: Screen, _ right: Int, _ y: Int, _ base: Style) {
    if let (text, color) = status {
      screen.text(right - textWidth(text), y, text, base.copyWith(fg: color, bold: true))
    }
  }
}

/// キーの案内（「Y はい」など）。キー部分を強調する。
@discardableResult
func drawHints(_ screen: Screen, _ x: Int, _ y: Int, _ hints: [(String, String)], _ base: Style, maxWidth: Int? = nil) -> Int {
  let limit = maxWidth.map { x + $0 } ?? screen.width
  var col = x
  for (key, label) in hints {
    let w = textWidth(key) + textWidth(label) + 2
    if col + w > limit {
      break
    }
    col += screen.text(col, y, key, base.copyWith(fg: Palette.lime, bold: true))
    col += screen.text(col, y, " \(label)", base.copyWith(fg: Palette.muted))
    col += screen.text(col, y, " ", base)
  }
  return col - x
}

/// [length] 件を [rows] 行で出すとき、[cursor] の行が見えるスクロール位置（先頭に出す番号）。
func fitScroll(cursor: Int, scroll: Int, length: Int, rows: Int) -> Int {
  var next = scroll
  if cursor < next {
    next = cursor
  } else if cursor >= next + rows {
    next = cursor - rows + 1
  }
  return min(max(next, 0), max(0, length - rows))
}
