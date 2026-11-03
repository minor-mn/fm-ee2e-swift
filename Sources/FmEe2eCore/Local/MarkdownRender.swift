import Markdown

/// Markdown のプレビューの文字の役割。色は描くときに、そのときの配色（[Palette]）から決める。
enum MarkdownRole: Hashable {
  case text
  case heading1
  case heading2
  case heading3

  /// 強調（*…*）。
  case emphasis

  /// コード（`…` とコードブロック）。
  case code
  case link

  /// リストの印・引用の線・区切り線・表の線など。
  case mark

  /// 打ち消し線・HTML・画像の代わりの文字など、薄く出すもの。
  case muted
}

/// 1行の中の、同じ見た目の切れ端。
struct MarkdownSpan: Equatable {
  var text: String
  var role: MarkdownRole = .text
  var bold = false

  /// リンク先（⌘+クリックで開く）。
  var link: String?
}

/// 描く1行。
typealias MarkdownLine = [MarkdownSpan]

/// [source] の Markdown を、幅 [width] の行にする。見出し・リスト・引用・コード・表・区切り線を描き分け、段落は幅で折り返す。
func renderMarkdown(_ source: String, width: Int) -> [MarkdownLine] {
  let width = max(8, width)
  return MarkdownRenderer.blocks(Array(Document(parsing: source).children), width)
}

/// [span] の見た目。[base] は地の見た目。
func markdownStyle(_ span: MarkdownSpan, _ base: Style) -> Style {
  var style = base
  switch span.role {
  case .text: break
  case .heading1: style = style.copyWith(fg: Palette.lime, bold: true)
  case .heading2: style = style.copyWith(fg: Palette.green, bold: true)
  case .heading3: style = style.copyWith(fg: Palette.cyan, bold: true)
  case .emphasis: style = style.copyWith(fg: Palette.purple)
  case .code: style = style.copyWith(fg: Palette.orange, bg: Palette.surfaceHigh)
  case .link: style = style.copyWith(fg: Palette.cyan, underline: true)
  case .mark: style = style.copyWith(fg: Palette.outline)
  case .muted: style = style.copyWith(fg: Palette.muted)
  }
  if span.bold {
    style = style.copyWith(bold: true)
  }
  if let link = span.link {
    style = style.copyWith(link: link)
  }
  return style
}

/// 行の幅（桁）。
func markdownWidth(_ line: MarkdownLine) -> Int { line.reduce(0) { $0 + textWidth($1.text) } }

private enum MarkdownRenderer {
  /// 並んだブロックの行。ブロックの間は1行空ける。
  static func blocks(_ children: [Markup], _ width: Int, gap: Bool = true) -> [MarkdownLine] {
    var lines: [MarkdownLine] = []
    for child in children {
      let block = self.block(child, width)
      if block.isEmpty {
        continue
      }
      if gap && !lines.isEmpty {
        lines.append([])
      }
      lines += block
    }
    return lines
  }

  static func block(_ markup: Markup, _ width: Int) -> [MarkdownLine] {
    switch markup {
    case let heading as Heading:
      let role: MarkdownRole = heading.level == 1 ? .heading1 : heading.level == 2 ? .heading2 : .heading3
      let lines = wrap(inlines(heading, MarkdownSpan(text: "", role: role, bold: true)), width)
      // 大きい見出しには、下に線を引く。
      return heading.level <= 2 ? lines + [[MarkdownSpan(text: String(repeating: heading.level == 1 ? "━" : "─", count: width), role: .mark)]] : lines
    case let paragraph as Paragraph:
      return wrap(inlines(paragraph, MarkdownSpan(text: "")), width)
    case let list as UnorderedList:
      return items(Array(list.listItems), width) { _ in "• " }
    case let list as OrderedList:
      let start = Int(list.startIndex)
      let count = list.childCount
      let digits = String(start + max(0, count - 1)).count
      return items(Array(list.listItems), width) { index in
        let number = String(start + index)
        return String(repeating: " ", count: digits - number.count) + number + ". "
      }
    case let quote as BlockQuote:
      return prefixed(blocks(Array(quote.children), width - 2), MarkdownSpan(text: "│ ", role: .mark), MarkdownSpan(text: "│ ", role: .mark))
    case let code as CodeBlock:
      return codeLines(code.code, width)
    case let html as HTMLBlock:
      return trailingTrimmed(html.rawHTML).split(separator: "\n", omittingEmptySubsequences: false).flatMap {
        wrap([MarkdownSpan(text: String($0), role: .muted)], width)
      }
    case is ThematicBreak:
      return [[MarkdownSpan(text: String(repeating: "─", count: width), role: .mark)]]
    case let table as Table:
      return self.table(table, width)
    default:
      return wrap([MarkdownSpan(text: markup.format(), role: .muted)], width)
    }
  }

  /// リストの項目。1つ目のブロックの頭に印（[mark]）を付け、続く行は印の幅だけ下げる。チェックボックスは印の後ろに出す。
  static func items(_ items: [ListItem], _ width: Int, _ mark: (Int) -> String) -> [MarkdownLine] {
    var lines: [MarkdownLine] = []
    for (index, item) in items.enumerated() {
      var head = mark(index)
      switch item.checkbox {
      case .checked: head += "☑ "
      case .unchecked: head += "☐ "
      case nil: break
      }
      let indent = textWidth(head)
      let body = blocks(Array(item.children), width - indent, gap: false)
      lines += prefixed(body.isEmpty ? [[]] : body, MarkdownSpan(text: head, role: .mark), MarkdownSpan(text: String(repeating: " ", count: indent)))
    }
    return lines
  }

  /// 1行目の頭に [first]、2行目からの頭に [rest] を付ける。
  static func prefixed(_ lines: [MarkdownLine], _ first: MarkdownSpan, _ rest: MarkdownSpan) -> [MarkdownLine] {
    lines.enumerated().map { [$0.offset == 0 ? first : rest] + $0.element }
  }

  /// コードブロック。行ごとに幅で折り返し、地の色で幅いっぱいまで塗る。
  static func codeLines(_ code: String, _ width: Int) -> [MarkdownLine] {
    trailingTrimmed(code).split(separator: "\n", omittingEmptySubsequences: false).flatMap { line -> [MarkdownLine] in
      // タブは4桁の空白にする（画面ではタブを描けない）。
      let text = String(line).replacingOccurrences(of: "\t", with: "    ")
      return wrap([MarkdownSpan(text: " " + text, role: .code)], width, words: false).map { line in
        let pad = width - markdownWidth(line)
        return pad > 0 ? line + [MarkdownSpan(text: String(repeating: " ", count: pad), role: .code)] : line
      }
    }
  }

  /// 表。列の幅は中身に合わせ、入りきらなければ広い列から縮めて、はみ出す中身は切る。見出しの行は太字。
  static func table(_ table: Table, _ width: Int) -> [MarkdownLine] {
    let columns = max(1, table.maxColumnCount)
    let rows: [[String]] = ([Array(table.head.cells)] + table.body.rows.map { Array($0.cells) }).map { cells in
      let texts = cells.map { $0.plainText.replacingOccurrences(of: "\n", with: " ") }
      return texts + Array(repeating: "", count: max(0, columns - texts.count))
    }
    var widths = (0..<columns).map { column in max(1, rows.map { textWidth($0[column]) }.max() ?? 1) }
    // 「│ 」と「 」で、列ごとに3桁、最後の「│」で1桁。
    let available = width - (columns * 3 + 1)
    while widths.reduce(0, +) > max(columns, available), let widest = widths.indices.max(by: { widths[$0] < widths[$1] }), widths[widest] > 1 {
      widths[widest] -= 1
    }
    let alignments = table.columnAlignments
    func border(_ left: String, _ middle: String, _ right: String) -> MarkdownLine {
      [MarkdownSpan(text: left + widths.map { String(repeating: "─", count: $0 + 2) }.joined(separator: middle) + right, role: .mark)]
    }
    func row(_ cells: [String], header: Bool) -> MarkdownLine {
      var line: MarkdownLine = []
      for (column, cell) in cells.enumerated() {
        let text = truncate(cell, widths[column])
        let pad = widths[column] - textWidth(text)
        let alignment = column < alignments.count ? alignments[column] : nil
        let before = alignment == .right ? pad : alignment == .center ? pad / 2 : 0
        line.append(MarkdownSpan(text: "│ ", role: .mark))
        line.append(MarkdownSpan(text: String(repeating: " ", count: before) + text + String(repeating: " ", count: pad - before) + " ", bold: header))
      }
      line.append(MarkdownSpan(text: "│", role: .mark))
      return line
    }
    return [border("┌", "┬", "┐"), row(rows[0], header: true), border("├", "┼", "┤")]
      + rows.dropFirst().map { row($0, header: false) }
      + [border("└", "┴", "┘")]
  }

  /// [markup] の中の文字を、見た目ごとの切れ端にする。[style] は外側から受け継ぐ見た目。改行（LineBreak）は「\n」の切れ端。
  static func inlines(_ markup: Markup, _ style: MarkdownSpan) -> [MarkdownSpan] {
    var spans: [MarkdownSpan] = []
    for child in markup.children {
      var inner = style
      switch child {
      case let text as Text:
        inner.text = text.string
        spans.append(inner)
      case is SoftBreak:
        inner.text = " "
        spans.append(inner)
      case is LineBreak:
        inner.text = "\n"
        spans.append(inner)
      case let code as InlineCode:
        inner.text = code.code
        inner.role = .code
        spans.append(inner)
      case let html as InlineHTML:
        inner.text = html.rawHTML
        inner.role = .muted
        spans.append(inner)
      case is Emphasis:
        if inner.role == .text {
          inner.role = .emphasis
        }
        spans += inlines(child, inner)
      case is Strong:
        inner.bold = true
        spans += inlines(child, inner)
      case is Strikethrough:
        inner.role = .muted
        spans += inlines(child, inner)
      case let link as Link:
        inner.role = .link
        inner.link = link.destination
        spans += inlines(child, inner)
      case let image as Image:
        // 画像は描けないので、代わりの文字（なければファイル名）を出す。
        inner.role = .muted
        let alt = image.plainText
        inner.text = "[\(alt.isEmpty ? image.source ?? "image" : alt)]"
        spans.append(inner)
      default:
        spans += inlines(child, inner)
      }
    }
    return spans
  }

  /// 切れ端を、幅 [width] で折り返した行にする。[words] なら英数字の語の途中では折り返さない（語が1行より長ければ切る）。
  /// 全角の文字は1文字ずつ、どこでも折り返せる。行の頭の空白は捨てる。
  static func wrap(_ spans: [MarkdownSpan], _ width: Int, words: Bool = true) -> [MarkdownLine] {
    var lines: [MarkdownLine] = []
    var line: MarkdownLine = []
    var used = 0
    func newLine() {
      lines.append(line)
      line = []
      used = 0
    }
    func append(_ text: String, _ span: MarkdownSpan) {
      if let last = line.last, last.role == span.role && last.bold == span.bold && last.link == span.link {
        line[line.count - 1].text += text
      } else {
        var piece = span
        piece.text = text
        line.append(piece)
      }
      used += textWidth(text)
    }
    for span in spans {
      if span.text == "\n" {
        newLine()
        continue
      }
      for token in tokens(span.text, words: words) {
        let w = textWidth(token)
        // コードでは空白も字下げなので、ほかの文字と同じに扱う。
        if words && token == " " {
          if used > 0 && used + 1 <= width {
            append(token, span)
          } else if used > 0 {
            newLine()
          }
          continue
        }
        if used + w > width && used > 0 {
          // 行の終わりの空白は落とす。
          if let last = line.last, last.text.hasSuffix(" ") {
            line[line.count - 1].text.removeLast()
            if line[line.count - 1].text.isEmpty {
              line.removeLast()
            }
          }
          newLine()
        }
        if w <= width {
          append(token, span)
          continue
        }
        // 1行に入らない語は、文字ごとに切る。
        for character in token {
          let cw = textWidth(String(character))
          if used + cw > width && used > 0 {
            newLine()
          }
          append(String(character), span)
        }
      }
    }
    if !line.isEmpty || lines.isEmpty {
      lines.append(line)
    }
    return lines
  }

  /// 折り返しの単位。空白は1つずつ、全角の文字は1文字ずつ、そのほかは続いている間（[words] でなければ1文字ずつ）。
  static func tokens(_ text: String, words: Bool) -> [String] {
    var tokens: [String] = []
    var word = ""
    func flush() {
      if !word.isEmpty {
        tokens.append(word)
        word = ""
      }
    }
    for character in text {
      if character == " " || character == "\t" {
        flush()
        tokens.append(words ? " " : String(character == "\t" ? " " : character))
      } else if !words || textWidth(String(character)) > 1 {
        flush()
        tokens.append(String(character))
      } else {
        word.append(character)
      }
    }
    flush()
    return tokens
  }

  /// 後ろの改行を除く。
  static func trailingTrimmed(_ s: String) -> String {
    var s = s
    while s.hasSuffix("\n") {
      s.removeLast()
    }
    return s
  }
}
