import AppKit

/// 24ビットカラー。
nonisolated struct Rgb: Hashable, Sendable {
  init(_ value: Int) {
    self.value = value
  }

  let value: Int

  var r: Int { (value >> 16) & 0xff }
  var g: Int { (value >> 8) & 0xff }
  var b: Int { value & 0xff }

  func mix(_ other: Rgb, _ t: Double) -> Rgb {
    func channel(_ a: Int, _ b: Int) -> Int { Int((Double(a) + Double(b - a) * t).rounded()) }
    return Rgb((channel(r, other.r) << 16) | (channel(g, other.g) << 8) | channel(b, other.b))
  }

  /// 同じ色を、不透明度 [opacity]（0〜1）で塗るもの（GUI 版だけ効く）。透け具合は上の8ビットに持つ。
  func withOpacity(_ opacity: Double) -> Rgb {
    value < 0 ? self : Rgb((value & 0xFFFFFF) | Int(((1 - opacity) * 255).rounded()) << 24)
  }

  /// [withOpacity] で決めた不透明度。
  var opacity: Double { value < 0 ? 1 : 1 - Double((value >> 24) & 0xff) / 255 }

  /// 不透明度を除いた色。
  var opaque: Rgb { value < 0 ? self : Rgb(value & 0xFFFFFF) }
}

extension Rgb {
  /// 枠の中の端末の、既定の文字色・地の色（描くときに、その範囲の [Palette.text]・[Palette.background] にする）。
  static let defaultForeground = Rgb(-1)
  static let defaultBackground = Rgb(-2)
}

/// テーマ色。描いている範囲の見た目（[Theme.active]）の色を返す。
nonisolated enum Palette {
  private static var colors: ThemeColors { Theme.active.colors }

  static var background: Rgb { colors.background }
  static var surface: Rgb { colors.surface }
  static var surfaceHigh: Rgb { colors.surfaceHigh }
  static var outline: Rgb { colors.outline }
  static var text: Rgb { colors.text }
  static var muted: Rgb { colors.muted }
  static var lime: Rgb { colors.lime }

  /// [lime] の上でも見分けられる、緑の強い黄緑。
  static var yellowGreen: Rgb { colors.yellowGreen }
  static var purple: Rgb { colors.purple }
  static var purpleDeep: Rgb { colors.purpleDeep }
  static var green: Rgb { colors.green }
  static var greenDeep: Rgb { colors.greenDeep }
  static var error: Rgb { colors.error }
  static var red: Rgb { colors.red }
  static var cyan: Rgb { colors.cyan }
  static var orange: Rgb { colors.orange }

  /// 右の窓（Google Drive・git・SSH）のカーソルの行の地の色。
  static var greenDark: Rgb { colors.greenDark }
  static var orangeDark: Rgb { colors.orangeDark }
  static var cyanDark: Rgb { colors.cyanDark }

  /// 差分の、追加した行・消した行の地の色。
  static var addedLine: Rgb { colors.addedLine }
  static var removedLine: Rgb { colors.removedLine }
  static var selected: Rgb { colors.selected }

  /// 窓の先頭の場所（パス）の色。
  static var location: Rgb { colors.location }

  /// ステータスバーの文字の色。
  static var statusbar: Rgb { colors.statusbar }

  /// ファイル名の色。
  static var directory: Rgb { colors.directory }
  static var executable: Rgb { colors.executable }
  static var hidden: Rgb { colors.hidden }
  static var marked: Rgb { colors.marked }
  static var symlink: Rgb { colors.symlink }

  /// 差分の、追加した行・消した行の印と数の色。
  static var diffAdded: Rgb { colors.diffAdded }
  static var diffRemoved: Rgb { colors.diffRemoved }
}

nonisolated struct Style: Hashable, Sendable {
  init(fg: Rgb = Palette.text, bg: Rgb = Palette.background, bold: Bool = false, underline: Bool = false, link: String? = nil) {
    self.fg = fg
    self.bg = bg
    self.bold = bold
    self.underline = underline
    self.link = link
  }

  var fg: Rgb
  var bg: Rgb
  var bold: Bool
  var underline: Bool

  /// リンク先の URL（⌘+クリックで開く）。
  var link: String?

  func copyWith(fg: Rgb? = nil, bg: Rgb? = nil, bold: Bool? = nil, underline: Bool? = nil, link: String? = nil) -> Style {
    Style(fg: fg ?? self.fg, bg: bg ?? self.bg, bold: bold ?? self.bold, underline: underline ?? self.underline, link: link ?? self.link)
  }

  /// リンク先だけを [link] にする（nil なら外す）。
  func withLink(_ link: String?) -> Style {
    Style(fg: fg, bg: bg, bold: bold, underline: underline, link: link)
  }
}

private nonisolated struct Cell: Equatable {
  /// 全角文字の右半分は空文字。
  var text: String
  var style: Style

  /// まだ何も書いていない、透明なセル（下の画面が見える）。重ねる画面（[Screen.layer] の clear）だけで使う。
  var clear = false

  static func == (a: Cell, b: Cell) -> Bool {
    // 文字はスカラー値で比べる（Swift の == は正規等価で比べるため）。
    a.style == b.style && a.clear == b.clear && a.text.unicodeScalars.elementsEqual(b.text.unicodeScalars)
  }
}

/// 画面のセルの大きさを決めるもの（GUI 版）。見た目ごとに文字の大きさが違うので、
/// [from] の見た目で幅 [width]・高さ [height] の範囲に、[to] の見た目のセルが何桁・何行入るかを返す。
protocol GridSizer: AnyObject {
  func gridSize(_ width: Int, _ height: Int, from: ThemeKey, to: ThemeKey) -> (Int, Int)
}

/// マウスで範囲を選んでコピーできる中身（GUI 版）。画面から流れた行も含めて、上から数えた行で扱う。
protocol SelectionSource: AnyObject {
  /// 行の数。
  var lineCount: Int { get }

  /// 画面の一番上に出している行。
  var firstVisibleLine: Int { get }

  /// [line] 行目のセルの文字（全角文字の右半分は空文字）と、端で折り返して次の行に続いているか。
  func lineCells(_ line: Int) -> (cells: [String], continues: Bool)

  /// 画面に出す行を [delta] 行ずらす（正なら新しい方へ）。
  func scrollLines(_ delta: Int)
}

/// 画面の上に重ねた画面（[Screen.layer]）。
final class ScreenLayer {
  init(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ screen: Screen, selection: SelectionSource?, framed: Bool, fill: Rgb?) {
    self.x = x
    self.y = y
    self.w = w
    self.h = h
    self.screen = screen
    self.selection = selection
    self.framed = framed
    self.fill = fill
  }

  /// 枠の中に塗る色（見た目の背景の代わり。GUI 版）。透明度は [ThemeColors.alphas] による。
  let fill: Rgb?

  /// 画面の縁に枠（[Screen.box]）を描く。GUI 版では、背景を枠の線の内側だけに塗る。
  let framed: Bool

  /// 親の画面のセルで数えた位置と大きさ。
  let x: Int
  let y: Int
  let w: Int
  let h: Int
  let screen: Screen

  /// マウスで範囲を選んでコピーできる中身（GUI 版）。選べなければ nil。
  private(set) weak var selection: SelectionSource?
}

/// 文字のセルの上に重ねる画像（プレビュー）。
struct ScreenImage {
  init(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ image: NSImage) {
    self.x = x
    self.y = y
    self.w = w
    self.h = h
    self.image = image
  }

  let x: Int
  let y: Int
  let w: Int
  let h: Int
  let image: NSImage
}

/// 1画面分の描画バッファ。窓（[GridView]）がこれを描く。
final class Screen {
  /// [theme] はこの画面の見た目、[sizer] は重ねる画面の大きさを決めるもの（なければ同じ大きさ）。
  /// [clear] なら、どのセルも透明（[layer] で重ねるダイアログ用）。
  init(_ width: Int, _ height: Int, theme: ThemeKey = .window, sizer: GridSizer? = nil, clear: Bool = false) {
    self.width = width
    self.height = height
    self.theme = theme
    self.sizer = sizer
    self.clear = clear
    cells = Array(repeating: Cell(text: " ", style: Style(), clear: clear), count: max(0, width * height))
  }

  let width: Int
  let height: Int
  let theme: ThemeKey
  let sizer: GridSizer?

  /// 透明なセルで始めた画面。
  let clear: Bool
  private var cells: [Cell]

  /// 入力欄など、端末のカーソルを表示する位置（IMEの変換位置にもなる）。
  var cursor: (x: Int, y: Int)?

  /// セルの上に重ねる画像。下のセルは空白にしておく。
  var image: ScreenImage?

  /// 上に重ねた画面（描いた順。後のものほど上）。
  private(set) var layers: [ScreenLayer] = []

  private func index(_ x: Int, _ y: Int) -> Int { y * width + x }

  /// [x]・[y] のセルの文字（全角文字の右半分は空文字）と書式。透明なセルは nil。
  func cell(_ x: Int, _ y: Int) -> (text: String, style: Style)? {
    let cell = cells[index(x, y)]
    return cell.clear ? nil : (cell.text, cell.style)
  }

  /// [x]・[y] から幅 [w]・高さ [h] の範囲に、見た目 [theme] の画面を重ねて [draw] で描く。
  /// GUI 版では文字の大きさが見た目ごとに違うので、重ねる画面の桁数・行数は [sizer] が決める。
  /// [clear] なら透明なセルで始め、書いたセルだけが下の画面を隠す。
  /// [selection] があれば、GUI 版でマウスで範囲を選んでコピーできる。
  func layer(
    _ x: Int, _ y: Int, _ w: Int, _ h: Int,
    theme: ThemeKey,
    clear: Bool = false,
    selection: SelectionSource? = nil,
    framed: Bool = false,
    fill: Rgb? = nil,
    _ draw: (Screen) -> Void
  ) {
    let w = max(0, min(w, width - x))
    let h = max(0, min(h, height - y))
    let previous = Theme.active
    Theme.active = Appearance.current.theme(theme)
    defer { Theme.active = previous }
    let (columns, rows) = sizer?.gridSize(w, h, from: self.theme, to: theme) ?? (w, h)
    let screen = Screen(max(0, columns), max(0, rows), theme: theme, sizer: sizer, clear: clear)
    draw(screen)
    layers.append(ScreenLayer(x, y, w, h, screen, selection: selection, framed: framed, fill: fill))
  }

  /// この画面と重ねた画面のカーソルを消す。
  func removeCursors() {
    cursor = nil
    for layer in layers {
      layer.screen.removeCursors()
    }
  }

  /// この画面と重ねた画面の画像を消す。
  func removeImages() {
    image = nil
    for layer in layers {
      layer.screen.removeImages()
    }
  }

  /// [col] から幅 [w] のセルに書く。全角文字の片側だけが残らないよう、はみ出した半分は空白にする。
  private func put(_ col: Int, _ y: Int, _ text: String, _ style: Style, _ w: Int) {
    if col > 0 && cells[index(col, y)].text.isEmpty {
      cells[index(col - 1, y)].text = " "
    }
    cells[index(col, y)] = Cell(text: text, style: style)
    if w == 2 && col + 1 < width {
      cells[index(col + 1, y)] = Cell(text: "", style: style)
    }
    let next = col + w
    if next < width && cells[index(next, y)].text.isEmpty {
      cells[index(next, y)].text = " "
    }
  }

  func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ style: Style, _ ch: String = " ") {
    var row = max(0, y)
    while row < min(height, y + h) {
      var col = max(0, x)
      while col < min(width, x + w) {
        put(col, row, ch, style, 1)
        col += 1
      }
      row += 1
    }
  }

  /// 文字列を書き、書いた幅を返す。[maxWidth] を超える分は書かない。
  @discardableResult
  func text(_ x: Int, _ y: Int, _ s: String, _ style: Style, maxWidth: Int? = nil) -> Int {
    if y < 0 || y >= height {
      return 0
    }
    let limit = maxWidth.map { min(max(x + $0, 0), width) } ?? width
    var col = x
    for cell in FmEe2eCore.cells(s) {
      let w = cellWidth(cell)
      if col + w > limit {
        break
      }
      if col >= 0 {
        put(col, y, cell, style, w)
      }
      col += w
    }
    return col - x
  }

  /// グラデーションで文字列を書く。
  @discardableResult
  func gradientText(_ x: Int, _ y: Int, _ s: String, _ colors: [Rgb], _ style: Style) -> Int {
    let list = FmEe2eCore.cells(s)
    var col = x
    for i in 0..<list.count {
      let t = list.count < 2 ? 0.0 : Double(i) / Double(list.count - 1) * Double(colors.count - 1)
      let index = min(max(Int(t.rounded(.down)), 0), max(colors.count - 2, 0))
      let color = colors.count == 1 ? colors[0] : colors[index].mix(colors[index + 1], t - Double(index))
      col += text(col, y, list[i], style.copyWith(fg: color))
    }
    return col - x
  }

  func box(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ style: Style, title: String? = nil, titleStyle: Style? = nil) {
    if w < 2 || h < 2 {
      return
    }
    let line = String(repeating: "─", count: w - 2)
    text(x, y, "╭\(line)╮", style)
    for row in (y + 1)..<(y + h - 1) {
      text(x, row, "│", style)
      text(x + w - 1, row, "│", style)
    }
    text(x, y + h - 1, "╰\(line)╯", style)
    if let title {
      text(x + 2, y, " \(truncate(title, w - 6)) ", titleStyle ?? style, maxWidth: w - 4)
    }
  }
}
