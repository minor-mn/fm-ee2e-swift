import Testing

@testable import FmEe2eCore

/// 行を、見た目を除いた文字だけにする。
private func plain(_ lines: [MarkdownLine]) -> [String] { lines.map { $0.map(\.text).joined() } }

struct MarkdownTests {
  @Test("見出し・段落・リスト・引用・コード・区切り線を描き分け、段落は幅で折り返す") func blocks() {
    let source = """
      # Title

      Some **bold** and `code` text that wraps.

      - one
      - [x] done
        1. nested

      > quoted

      ```
      let x = 1
        indented
      ```

      ---
      """
    #expect(
      plain(renderMarkdown(source, width: 20)) == [
        "Title",
        String(repeating: "━", count: 20),
        "",
        "Some bold and code",
        "text that wraps.",
        "",
        "• one",
        "• ☑ done",
        "    1. nested",
        "",
        "│ quoted",
        "",
        " let x = 1          ",
        "   indented         ",
        "",
        String(repeating: "─", count: 20),
      ]
    )
  }

  @Test("全角の文字は1文字ずつ折り返し、太字とリンクは切れ端に残す") func wrapsWideText() {
    let lines = renderMarkdown("日本語の文章を**折り返す**[リンク](https://example.com)", width: 8)
    #expect(plain(lines) == ["日本語の", "文章を折", "り返すリ", "ンク"])
    #expect(lines[1].contains { $0.bold && $0.text == "折" })
    #expect(lines[3].first?.link == "https://example.com")
  }

  @Test("表は列の幅を中身に揃え、見出しの行を区切る") func table() {
    let source = """
      | a | bb |
      |---|---:|
      | 1 | 2 |
      """
    #expect(
      plain(renderMarkdown(source, width: 40)) == [
        "┌───┬────┐",
        "│ a │ bb │",
        "├───┼────┤",
        "│ 1 │  2 │",
        "└───┴────┘",
      ]
    )
  }
}
