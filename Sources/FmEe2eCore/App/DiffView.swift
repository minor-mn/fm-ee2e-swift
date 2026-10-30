/// 差分の画面に出す1ファイル分と、それがどのブロックのものか（staged・not staged・untracked）。
typealias DiffPage = (file: DiffFile, section: String)

/// 差分を画面全体に GitHub の Unified 表示のように出す。左に変更前・変更後の行番号、追加した行は緑、消した行は赤の地。
final class DiffView: Modal {
  init(_ pages: [DiffPage], _ close: @escaping (()) -> Void, page: Int = 0) {
    self.pages = pages
    self.close = close
    self.page = min(max(page, 0), pages.count - 1)
    super.init("git diff", accent: Appearance.current.theme(.git).colors.accent(or: \.orange))
  }

  /// git のタブの見た目で描く。
  override var themeKey: ThemeKey { .git }

  let pages: [DiffPage]
  let close: (()) -> Void
  private var page: Int
  private var scroll = 0

  private var file: DiffFile { pages[page].file }

  override var frame: ModalFrame { .page }

  override var hints: [(String, String)] {
    [("↑↓ PgUp PgDn", tr("diff_view.hints.scroll")), ("n / p", tr("diff_view.hints.next_prev"))]
      + (pages.count > 1 ? [("← →", tr("diff_view.hints.files"))] : [])
      + [("Esc / q", tr("diff_view.hints.back"))]
  }

  override func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ width: Int) {
    let lines = file.lines
    scroll = min(max(scroll, 0), max(0, lines.count - bodyRows))
    if file.binary || lines.isEmpty {
      screen.text(
        x + 2,
        y + 1,
        file.binary
          ? tr("diff_view.binary")
          : pages[page].section == "untracked"
          ? tr("diff_view.empty_file")
          : tr("diff_view.no_content_diff"),
        background.copyWith(fg: Palette.muted)
      )
    }
    // 行番号の欄は、このファイルで一番大きい番号が入る幅にする。
    let biggest = lines.reduce(0) { m, l in max(m, max(l.oldNumber ?? 0, l.newNumber ?? 0)) }
    let numberWidth = max(3, "\(biggest)".count)
    var i = 0
    while i < bodyRows && scroll + i < lines.count {
      drawLine(screen, y + i, width, lines[scroll + i], numberWidth)
      i += 1
    }
  }

  /// 上の帯に、ファイル名と増減、どのブロックのものかを出す。
  override func drawTitle(_ screen: Screen, _ x: Int, _ y: Int, _ width: Int) {
    let bar = Modal.bar
    let page = pages[self.page]
    let end = x + width
    var x = x
    if pages.count > 1 {
      x += screen.text(x, y, "\(self.page + 1)/\(pages.count)  ", bar.copyWith(fg: Palette.muted))
    }
    let name = page.file.from == nil ? page.file.path : "\(page.file.from!) -> \(page.file.path)"
    let tail = "  +\(page.file.added) -\(page.file.removed)  \(page.section)"
    x += screen.text(
      x,
      y,
      truncateLeft(name, max(1, end - x - textWidth(tail))),
      bar.copyWith(fg: accent, bold: true)
    )
    x += screen.text(x, y, "  ", bar)
    x += screen.text(x, y, "+\(page.file.added)", bar.copyWith(fg: Palette.diffAdded, bold: true))
    x += screen.text(x, y, " ", bar)
    x += screen.text(x, y, "-\(page.file.removed)", bar.copyWith(fg: Palette.diffRemoved, bold: true))
    screen.text(x + 2, y, page.section, bar.copyWith(fg: Palette.muted))
  }

  private func drawLine(_ screen: Screen, _ y: Int, _ w: Int, _ line: DiffLine, _ numberWidth: Int) {
    if line.kind == .hunk {
      // 変更の固まりの区切り。git の @@ の行の代わりに、行番号と、git が添える関数名などを出す。
      let style = Style(fg: Palette.muted, bg: Palette.surface)
      screen.fill(0, y, w, 1, style)
      let where_ = tr("diff_view.hunk_from", ["line": line.newNumber ?? 0])
      let x = 1 + screen.text(1, y, where_, style.copyWith(bold: true))
      if !line.text.isEmpty {
        screen.text(x + 2, y, truncate(DiffView.plain(line.text), max(0, w - x - 3)), style)
      }
      return
    }
    let (sign, bg): (String, Rgb) =
      switch line.kind {
      case .added: ("+", Palette.addedLine)
      case .removed: ("-", Palette.removedLine)
      default: (" ", Palette.background)
      }
    let style = Style(bg: bg)
    screen.fill(0, y, w, 1, style)
    let numbers = style.copyWith(fg: Palette.muted)
    func number(_ n: Int?) -> String { padLeft(n == nil ? "" : "\(n!)", numberWidth) }
    var x = 1
    x += screen.text(x, y, number(line.oldNumber), numbers) + 1
    x += screen.text(x, y, number(line.newNumber), numbers) + 1
    if line.kind == .note {
      screen.text(x + 2, y, truncate(line.text, max(0, w - x - 3)), numbers)
      return
    }
    x += screen.text(x, y, sign, style.copyWith(fg: sign == "+" ? Palette.diffAdded : Palette.diffRemoved, bold: true)) + 1
    screen.text(x, y, truncate(DiffView.plain(line.text), max(0, w - x - 1)), style)
  }

  /// タブを空白にし、制御文字を消す（画面の桁がずれないように）。
  private static func plain(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      if scalar == "\t" {
        out.append(contentsOf: "    ".unicodeScalars)
      } else if !(scalar.value <= 0x08 || (0x0b...0x1f).contains(scalar.value) || scalar.value == 0x7f) {
        out.append(scalar)
      }
    }
    return String(out)
  }

  override func handleKey(_ key: Key) {
    let lines = file.lines
    switch key.name {
    case "up":
      scroll -= 1
    case "down":
      scroll += 1
    case "pageUp":
      scroll -= bodyRows
    case "pageDown":
      scroll += bodyRows
    case "home":
      scroll = 0
    case "end":
      scroll = lines.count
    case "left":
      turn(-1)
    case "right":
      turn(1)
    case "escape":
      close(())
    case "char":
      switch key.char!.lowercased() {
      case "q":
        close(())
      case "n":
        jump(1)
      case "p":
        jump(-1)
      default:
        break
      }
    default:
      break
    }
    scroll = min(max(scroll, 0), max(0, lines.count - bodyRows))
  }

  private func turn(_ delta: Int) {
    let next = min(max(page + delta, 0), pages.count - 1)
    if next != page {
      page = next
      scroll = 0
    }
  }

  /// 次（[step] が 1）・前（-1）の変更の固まりを、一番上に出す。
  private func jump(_ step: Int) {
    let lines = file.lines
    var i = scroll + step
    while i >= 0 && i < lines.count {
      if lines[i].kind == .hunk {
        scroll = i
        return
      }
      i += step
    }
  }
}
