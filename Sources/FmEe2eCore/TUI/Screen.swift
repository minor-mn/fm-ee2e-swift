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
}

/// テーマ色。
nonisolated enum Palette {
  static let background = Rgb(0x12161D)
  static let surface = Rgb(0x181D26)
  static let surfaceHigh = Rgb(0x212835)
  static let outline = Rgb(0x2C3342)
  static let text = Rgb(0xEDEFF2)
  static let muted = Rgb(0x98A1B0)
  static let lime = Rgb(0xE3F86A)

  /// [lime] の上でも見分けられる、緑の強い黄緑。
  static let yellowGreen = Rgb(0x8EDB3C)
  static let purple = Rgb(0x9B6BFF)
  static let purpleDeep = Rgb(0x5B34C9)
  static let green = Rgb(0x2EE0A8)
  static let greenDeep = Rgb(0x128F6D)
  static let error = Rgb(0xFF7A6B)
  static let red = Rgb(0xFF4D5E)
  static let cyan = Rgb(0x5CD8FF)
  static let orange = Rgb(0xFF9F43)

  /// 右の窓（Google Drive・git・SSH）のカーソルの行の地の色。
  static let greenDark = Rgb(0x0F4A3A)
  static let orangeDark = Rgb(0x6B3A12)
  static let cyanDark = Rgb(0x124A5E)

  /// 差分の、追加した行・消した行の地の色。
  static let addedLine = Rgb(0x12392D)
  static let removedLine = Rgb(0x481C24)
  static let selected = Rgb(0x3A2A6E)
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

  /// リンク先の URL（OSC 8 のハイパーリンクにする。iTerm2 では Command+クリックで開く）。
  var link: String?

  func copyWith(fg: Rgb? = nil, bg: Rgb? = nil, bold: Bool? = nil, underline: Bool? = nil, link: String? = nil) -> Style {
    Style(fg: fg ?? self.fg, bg: bg ?? self.bg, bold: bold ?? self.bold, underline: underline ?? self.underline, link: link ?? self.link)
  }

  /// リンク先だけを [link] にする（nil なら外す）。
  func withLink(_ link: String?) -> Style {
    Style(fg: fg, bg: bg, bold: bold, underline: underline, link: link)
  }

  var sgr: String {
    "\u{1b}[0;\(bold ? "1;" : "")\(underline ? "4;" : "")38;2;\(fg.r);\(fg.g);\(fg.b);48;2;\(bg.r);\(bg.g);\(bg.b)m"
  }
}

private nonisolated struct Cell: Equatable {
  /// 全角文字の右半分は空文字。
  var text: String
  var style: Style

  static func == (a: Cell, b: Cell) -> Bool {
    // 文字はスカラー値で比べる（Swift の == は正規等価で比べるため）。
    a.style == b.style && a.text.unicodeScalars.elementsEqual(b.text.unicodeScalars)
  }
}

/// 文字のセルの上に重ねる画像（iTerm2 の画像表示）。
nonisolated struct ScreenImage: Sendable {
  init(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ id: String, _ base64: String, name: String = "", size: Int = 0) {
    self.x = x
    self.y = y
    self.w = w
    self.h = h
    self.id = id
    self.base64 = base64
    self.name = name
    self.size = size
  }

  let x: Int
  let y: Int
  let w: Int
  let h: Int

  /// 同じ画像かを見分ける名前。
  let id: String
  let base64: String

  /// iTerm2 の確認ダイアログに出る名前（base64）と、画像のバイト数。
  let name: String
  let size: Int

  func covers(_ row: Int) -> Bool { row >= y && row < y + h }

  func same(_ other: ScreenImage?) -> Bool {
    guard let other else { return false }
    return other.id == id && other.x == x && other.y == y && other.w == w && other.h == h
  }
}

/// 1画面分の描画バッファ。前回との差分の行だけを端末に書く。
final class Screen {
  init(_ width: Int, _ height: Int) {
    self.width = width
    self.height = height
    cells = Array(repeating: Cell(text: " ", style: Style()), count: max(0, width * height))
  }

  let width: Int
  let height: Int
  private var cells: [Cell]

  /// 入力欄など、端末のカーソルを表示する位置（IMEの変換位置にもなる）。
  var cursor: (x: Int, y: Int)?

  /// セルの上に重ねる画像。下のセルは空白にしておく。
  var image: ScreenImage?

  private func index(_ x: Int, _ y: Int) -> Int { y * width + x }

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

  /// [previous] との差分を端末へのエスケープシーケンスにする。
  /// 画像は、前回と同じなら下のセルを書かずに残し、変わったときだけ描き直す。
  func diff(_ previous: Screen?) -> String {
    var out = ""
    let full = previous == nil || previous!.width != width || previous!.height != height
    let img = image
    let keep = !full && img != nil && img!.same(previous!.image)
    let old = full ? nil : previous!.image
    for y in 0..<height {
      // 前回の画像が消えたり動いたりした行は、画像を消すために書き直す。
      let erase = old != nil && !keep && old!.covers(y)
      if !full && !erase && rowEquals(previous!, y) {
        continue
      }
      // 残す画像の下のセルは書かない（書くと画像が消える）。
      let skip = keep && img!.covers(y)
      out += "\u{1b}[\(y + 1);1H"
      var current: Style?
      // 開いているリンク（OSC 8）。行の終わりでは必ず閉じる。
      var link: String?
      func linkTo(_ url: String?) {
        if url != link {
          out += "\u{1b}]8;;\(url ?? "")\u{1b}\\"
          link = url
        }
      }
      var x = 0
      while x < width {
        if skip, let img, x == img.x {
          linkTo(nil)
          x = img.x + img.w - 1
          out += "\u{1b}[\(y + 1);\(x + 2)H"
          x += 1
          continue
        }
        let cell = cells[index(x, y)]
        x += 1
        if cell.text.isEmpty {
          continue
        }
        if cell.style != current {
          current = cell.style
          out += cell.style.sgr
          linkTo(cell.style.link)
        }
        out += cell.text
      }
      linkTo(nil)
    }
    out += "\u{1b}[0m"
    if let img, !keep {
      out +=
        "\u{1b}[\(img.y + 1);\(img.x + 1)H"
        + "\u{1b}]1337;File=\(img.name.isEmpty ? "" : "name=\(img.name);")size=\(img.size);inline=1;"
        + "width=\(img.w);height=\(img.h);preserveAspectRatio=1:\(img.base64)\u{07}"
    }
    if let c = cursor {
      out += "\u{1b}[\(c.y + 1);\(c.x + 1)H\u{1b}[?25h"
    } else {
      out += "\u{1b}[?25l"
    }
    return out
  }

  private func rowEquals(_ other: Screen, _ y: Int) -> Bool {
    for x in 0..<width where cells[index(x, y)] != other.cells[other.index(x, y)] {
      return false
    }
    return true
  }
}
