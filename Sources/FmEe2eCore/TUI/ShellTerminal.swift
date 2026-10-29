final class ShellCell {
  init(_ text: String = " ", _ style: Style = Style()) {
    self.text = text
    self.style = style
  }

  var text: String
  var style: Style
}

/// 枠の中で動かすプログラムの出力をセルに解釈する。制御文字を外側の端末へ直接書かない。
final class ShellTerminal {
  init(_ columns: Int, _ rows: Int) {
    self.columns = columns
    self.rows = rows
    bottom = rows - 1
    grid = []
    grid = blank()
  }

  var columns: Int
  var rows: Int
  private var grid: [[ShellCell]]
  private var primary: [[ShellCell]]?
  private var primaryCursor: (Int, Int)?
  var x = 0
  var y = 0
  private var savedX = 0
  private var savedY = 0
  private var top = 0
  private var bottom: Int
  private var wrap = false
  private var autoWrap = true
  private var origin = false
  private var insert = false
  var cursorVisible = true
  var applicationCursor = false
  var bracketedPaste = false
  private var inverse = false
  private var style = Style()
  private var state = ""
  private var sequence = ""

  /// [sequence] の文字数（毎回数え直さないため）。
  private var sequenceLength = 0
  private var stringEscape = false

  /// 端末状態の問い合わせに対する応答（SSH の入力へ返す）。
  var onResponse: ((String) -> Void)?

  /// 画面の上から流れた行（古い順）。代替画面（全画面のプログラム）の分は残さない。
  private(set) var scrollback: [[ShellCell]] = []

  /// [scrollback] に残す行数の上限。
  static let scrollbackLimit = 5000

  func cell(_ col: Int, _ row: Int) -> ShellCell { grid[row][col] }
  func line(_ row: Int) -> String { grid[row].map(\.text).joined() }
  private func row() -> [ShellCell] { (0..<columns).map { _ in ShellCell() } }
  private func blank() -> [[ShellCell]] { (0..<rows).map { _ in row() } }
  private var paint: Style { inverse ? style.copyWith(fg: style.bg, bg: style.fg) : style }

  func resize(_ width: Int, _ height: Int) {
    if width == columns && height == rows {
      return
    }
    let oldRows = rows
    columns = max(2, width)
    rows = max(1, height)
    // 高さが減ったときはカーソルを含む末尾を残す。
    let shift = max(0, y - rows + 1)
    func fit(_ old: [[ShellCell]], _ offset: Int) -> [[ShellCell]] {
      (0..<rows).map { row in
        let source = row + offset < old.count ? old[row + offset] : []
        var result = (0..<columns).map { col in col < source.count ? source[col] : ShellCell() }
        if !result[result.count - 1].text.isEmpty && cellWidth(result[result.count - 1].text) == 2 {
          result[result.count - 1] = ShellCell()
        }
        return result
      }
    }
    grid = fit(grid, shift)
    if let primary {
      self.primary = fit(primary, 0)
    }
    x = clamp(x, 0, columns - 1)
    y = clamp(y - (oldRows > rows ? shift : 0), 0, rows - 1)
    top = 0
    bottom = rows - 1
    wrap = false
  }

  func write(_ text: String) {
    for scalar in text.unicodeScalars {
      let rune = Int(scalar.value)
      if state == "string" {
        if rune == 7 || (stringEscape && rune == 0x5c /* \ */) {
          state = ""
          osc(sequence)
        } else if rune != 27 && sequenceLength < 4096 {
          appendSequence(scalar)
        }
        stringEscape = rune == 27
        continue
      }
      if rune == 27 {
        state = "escape"
        clearSequence()
        continue
      }
      if state == "escape" {
        state = ""
        switch scalar {
        case "[":
          state = "csi"
        case "]", "P", "^", "_":
          state = "string"
          stringEscape = false
          // OSC（]）だけ中身を読む。
          clearSequence()
          if scalar != "]" {
            appendSequence("-")
          }
        case "(", ")", "*", "+", "#", "%":
          state = "charset"
        case "7":
          save()
        case "8":
          restore()
        case "D":
          lineFeed()
        case "E":
          x = 0
          lineFeed()
        case "M":
          reverseIndex()
        case "c":
          reset()
        default:
          break
        }
        continue
      }
      if state == "charset" {
        state = ""
        continue
      }
      if state == "csi" {
        if rune >= 0x40 && rune <= 0x7e {
          csi(String(scalar), sequence)
          state = ""
        } else if sequenceLength < 256 {
          appendSequence(scalar)
        } else {
          state = ""
        }
        continue
      }
      switch rune {
      case 8:
        x = max(0, x - 1)
        wrap = false
      case 9:
        x = min(columns - 1, (x / 8 + 1) * 8)
        wrap = false
      case 10, 11, 12:
        lineFeed()
      case 13:
        x = 0
        wrap = false
      default:
        if rune >= 32 && rune != 127 {
          put(String(scalar), runeWidth(scalar.value))
        }
      }
    }
  }

  private func appendSequence(_ scalar: Unicode.Scalar) {
    sequence.unicodeScalars.append(scalar)
    sequenceLength += 1
  }

  private func clearSequence() {
    sequence = ""
    sequenceLength = 0
  }

  private func clearCell(_ col: Int, _ row: Int) {
    if grid[row][col].text.isEmpty && col > 0 {
      grid[row][col - 1] = ShellCell(" ", paint)
    }
    if cellWidth(grid[row][col].text) == 2 && col + 1 < columns {
      grid[row][col + 1] = ShellCell(" ", paint)
    }
    grid[row][col] = ShellCell(" ", paint)
  }

  private func put(_ ch: String, _ width: Int) {
    if width == 0 {
      var at = wrap ? x : x - 1
      while at > 0 && grid[y][at].text.isEmpty {
        at -= 1
      }
      if at >= 0 {
        grid[y][at].text = composeKana(grid[y][at].text + ch)
      }
      return
    }
    if wrap || (width == 2 && x == columns - 1) {
      if autoWrap {
        x = 0
        lineFeed()
      }
      wrap = false
    }
    if width == 2 && x + 1 >= columns {
      return
    }
    if insert {
      insertChars(width)
    }
    clearCell(x, y)
    if width == 2 {
      clearCell(x + 1, y)
    }
    grid[y][x] = ShellCell(ch, paint)
    if width == 2 {
      grid[y][x + 1] = ShellCell("", paint)
    }
    x += width
    if x >= columns {
      x = columns - 1
      wrap = autoWrap
    }
  }

  private func lineFeed() {
    wrap = false
    if y == bottom {
      scroll(1)
    } else {
      y = min(rows - 1, y + 1)
    }
  }

  private func reverseIndex() {
    if y == top {
      scroll(-1)
    } else {
      y = max(0, y - 1)
    }
    wrap = false
  }

  private func scroll(_ count: Int) {
    var i = 0
    while i < min(abs(count), bottom - top + 1) {
      if count > 0 {
        let removed = grid.remove(at: top)
        if primary == nil && top == 0 {
          scrollback.append(removed)
          if scrollback.count > ShellTerminal.scrollbackLimit {
            scrollback.removeFirst()
          }
        }
        grid.insert(row(), at: bottom)
      } else {
        grid.remove(at: bottom)
        grid.insert(row(), at: top)
      }
      i += 1
    }
  }

  private func eraseLine(_ row: Int, _ from: Int, _ to: Int) {
    var col = from
    while col <= to {
      clearCell(col, row)
      col += 1
    }
  }

  private func insertChars(_ count: Int) {
    let n = min(count, columns - x)
    if n <= 0 {
      return
    }
    grid[y].insert(contentsOf: (0..<n).map { _ in ShellCell(" ", paint) }, at: x)
    grid[y].removeSubrange(columns..<(columns + n))
  }

  private func save() {
    savedX = x
    savedY = y
  }

  private func restore() {
    x = clamp(savedX, 0, columns - 1)
    y = clamp(savedY, 0, rows - 1)
    wrap = false
  }

  private func csi(_ command: String, _ raw: String) {
    let isPrivate = raw.hasPrefix("?")
    let body = raw.first.map { "?>!".contains($0) } == true ? String(raw.dropFirst()) : raw
    // 桁あふれで止まらないよう、値の大きさを抑える。
    let values = body.split(separator: ";", omittingEmptySubsequences: false).map { clamp(Int($0) ?? 0, -1_000_000, 1_000_000) }
    func arg(_ index: Int, _ fallback: Int = 1) -> Int {
      index >= values.count || values[index] == 0 ? fallback : values[index]
    }
    let n = arg(0)
    let minY = origin ? top : 0
    let maxY = origin ? bottom : rows - 1
    if command != "m" {
      wrap = false
    }
    switch command {
    case "A":
      y = max(minY, y - n)
    case "B", "e":
      y = min(maxY, y + n)
    case "C", "a":
      x = min(columns - 1, x + n)
    case "D":
      x = max(0, x - n)
    case "E":
      x = 0
      y = min(maxY, y + n)
    case "F":
      x = 0
      y = max(minY, y - n)
    case "G", "`":
      x = clamp(n - 1, 0, columns - 1)
    case "d":
      y = clamp(minY + n - 1, minY, maxY)
    case "H", "f":
      y = clamp(minY + n - 1, minY, maxY)
      x = clamp(arg(1) - 1, 0, columns - 1)
    case "J":
      let mode = arg(0, 0)
      if mode == 0 {
        eraseLine(y, x, columns - 1)
        for row in (y + 1)..<max(y + 1, rows) {
          eraseLine(row, 0, columns - 1)
        }
      } else if mode == 1 {
        for row in 0..<y {
          eraseLine(row, 0, columns - 1)
        }
        eraseLine(y, 0, x)
      } else if mode == 2 {
        grid = blank()
      }
    case "K":
      let mode = arg(0, 0)
      eraseLine(y, mode == 0 ? x : 0, mode == 1 ? x : columns - 1)
    case "X":
      eraseLine(y, x, min(columns - 1, x + n - 1))
    case "@":
      insertChars(n)
    case "P":
      let end = min(columns, x + n)
      if end > x {
        grid[y].removeSubrange(x..<end)
        grid[y].append(contentsOf: (0..<(end - x)).map { _ in ShellCell(" ", paint) })
      }
    case "L", "M":
      if y >= top && y <= bottom {
        let saved = top
        top = y
        scroll(command == "L" ? -n : n)
        top = saved
      }
    case "S":
      scroll(n)
    case "T":
      scroll(-n)
    case "r":
      let newTop = n - 1
      let newBottom = arg(1, rows) - 1
      if newTop >= 0 && newTop < newBottom && newBottom < rows {
        top = newTop
        bottom = newBottom
        x = 0
        y = origin ? newTop : 0
      }
    case "s":
      save()
    case "u":
      restore()
    case "m":
      sgr(values)
    case "h", "l":
      let enabled = command == "h"
      for mode in values {
        if !isPrivate {
          if mode == 4 {
            insert = enabled
          }
          continue
        }
        switch mode {
        case 1:
          applicationCursor = enabled
        case 6:
          origin = enabled
          x = 0
          y = enabled ? top : 0
        case 7:
          autoWrap = enabled
        case 25:
          cursorVisible = enabled
        case 47, 1047, 1049:
          alternate(enabled)
        case 2004:
          bracketedPaste = enabled
        default:
          break
        }
      }
    case "n":
      if n == 5 {
        onResponse?("\u{1b}[0n")
      }
      if n == 6 {
        onResponse?("\u{1b}[\(y + 1);\(x + 1)R")
      }
    case "c":
      onResponse?(raw.hasPrefix(">") ? "\u{1b}[>0;0;0c" : "\u{1b}[?1;2c")
    default:
      break
    }
  }

  /// OSC のうち、ハイパーリンク（OSC 8: `8;パラメーター;URL`）だけを扱う。URL が空ならリンクを終える。
  private func osc(_ body: String) {
    let parts = body.split(separator: ";", omittingEmptySubsequences: false)
    if parts.count < 3 || parts[0] != "8" {
      return
    }
    let url = parts[2...].joined(separator: ";")
    style = style.withLink(url.isEmpty ? nil : url)
  }

  private func alternate(_ enabled: Bool) {
    if enabled && primary == nil {
      primary = grid
      primaryCursor = (x, y)
      grid = blank()
      x = 0
      y = 0
    } else if !enabled, let saved = primary {
      grid = saved
      primary = nil
      x = clamp(primaryCursor!.0, 0, columns - 1)
      y = clamp(primaryCursor!.1, 0, rows - 1)
    }
    top = 0
    bottom = rows - 1
    wrap = false
  }

  private func reset() {
    primary = nil
    grid = blank()
    x = 0
    y = 0
    top = 0
    bottom = rows - 1
    style = Style()
    inverse = false
    origin = false
    insert = false
    autoWrap = true
    wrap = false
    cursorVisible = true
    applicationCursor = false
    bracketedPaste = false
  }

  private func sgr(_ values: [Int]) {
    var i = 0
    while i < values.count {
      let code = values[i]
      switch code {
      case 0:
        // 色などを戻しても、リンクは OSC 8 で終えるまで続く。
        style = Style().withLink(style.link)
        inverse = false
      case 1:
        style = style.copyWith(bold: true)
      case 22:
        style = style.copyWith(bold: false)
      case 4:
        style = style.copyWith(underline: true)
      case 24:
        style = style.copyWith(underline: false)
      case 7:
        inverse = true
      case 27:
        inverse = false
      case 39:
        style = style.copyWith(fg: Palette.text)
      case 49:
        style = style.copyWith(bg: Palette.background)
      case 38, 48:
        var color: Rgb?
        if i + 2 < values.count && values[i + 1] == 5 {
          color = ShellTerminal.color(values[i + 2])
          i += 2
        } else if i + 4 < values.count && values[i + 1] == 2 {
          color = Rgb(
            (clamp(values[i + 2], 0, 255) << 16) | (clamp(values[i + 3], 0, 255) << 8) | clamp(values[i + 4], 0, 255)
          )
          i += 4
        }
        if let color {
          style = code == 38 ? style.copyWith(fg: color) : style.copyWith(bg: color)
        }
      default:
        if code >= 30 && code <= 37 {
          style = style.copyWith(fg: ShellTerminal.color(code - 30))
        }
        if code >= 40 && code <= 47 {
          style = style.copyWith(bg: ShellTerminal.color(code - 40))
        }
        if code >= 90 && code <= 97 {
          style = style.copyWith(fg: ShellTerminal.color(code - 90 + 8))
        }
        if code >= 100 && code <= 107 {
          style = style.copyWith(bg: ShellTerminal.color(code - 100 + 8))
        }
      }
      i += 1
    }
  }

  private static let basic = [
    0x000000,
    0xcd3131,
    0x0dbc79,
    0xe5e510,
    0x2472c8,
    0xbc3fbc,
    0x11a8cd,
    0xe5e5e5,
    0x666666,
    0xf14c4c,
    0x23d18b,
    0xf5f543,
    0x3b8eea,
    0xd670d6,
    0x29b8db,
    0xffffff,
  ]

  private static let cube = [0, 95, 135, 175, 215, 255]

  private static func color(_ value: Int) -> Rgb {
    let index = clamp(value, 0, 255)
    if index < 16 {
      return Rgb(basic[index])
    }
    if index >= 232 {
      let c = 8 + (index - 232) * 10
      return Rgb((c << 16) | (c << 8) | c)
    }
    let c = index - 16
    return Rgb((cube[c / 36] << 16) | (cube[(c / 6) % 6] << 8) | cube[c % 6])
  }
}

/// Dart の int.clamp。
private func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int { min(max(value, low), high) }
