import Testing

@testable import FmEe2eCore

@MainActor
struct ShellTerminalTests {
  /// 行の末尾の空白を除いた文字。
  private func text(_ t: ShellTerminal, _ row: Int) -> String {
    var s = t.line(row)
    while s.hasSuffix(" ") {
      s.removeLast()
    }
    return s
  }

  @Test func printsTextAndMovesCursor() {
    let t = ShellTerminal(10, 3)
    t.write("abc\r\ndef")
    #expect(text(t, 0) == "abc")
    #expect(text(t, 1) == "def")
    #expect(t.x == 3 && t.y == 1)
  }

  @Test func wrapsAtLastColumnAndScrollsIntoScrollback() {
    let t = ShellTerminal(4, 2)
    t.write("abcdefgh")
    // 4文字目のあとは折り返し待ち。5文字目で次の行、9文字目はない。
    #expect(text(t, 0) == "abcd")
    #expect(text(t, 1) == "efgh")
    t.write("i")
    #expect(t.scrollback.count == 1)
    #expect(t.scrollback[0].map(\.text).joined() == "abcd")
    #expect(text(t, 0) == "efgh")
    #expect(text(t, 1) == "i")
  }

  @Test func wideCharactersTakeTwoCells() {
    let t = ShellTerminal(5, 2)
    t.write("あい")
    #expect(t.cell(0, 0).text == "あ")
    #expect(t.cell(1, 0).text == "")
    #expect(t.cell(2, 0).text == "い")
    #expect(t.x == 4)
    // 最後の1桁には入らないので次の行へ。
    t.write("う")
    #expect(t.cell(4, 0).text == " ")
    #expect(t.cell(0, 1).text == "う")
  }

  @Test func combiningMarkJoinsPreviousCell() {
    let t = ShellTerminal(5, 1)
    t.write("か\u{3099}")
    #expect(t.cell(0, 0).text == "が")
  }

  @Test func cursorMovementSequences() {
    let t = ShellTerminal(10, 5)
    t.write("\u{1b}[3;4H")
    #expect(t.x == 3 && t.y == 2)
    t.write("\u{1b}[A\u{1b}[2C")
    #expect(t.x == 5 && t.y == 1)
    t.write("\u{1b}[10B\u{1b}[99D")
    #expect(t.x == 0 && t.y == 4)
    t.write("\u{1b}[7G\u{1b}[2d")
    #expect(t.x == 6 && t.y == 1)
    t.write("\u{1b}[H")
    #expect(t.x == 0 && t.y == 0)
  }

  @Test func saveAndRestoreCursor() {
    let t = ShellTerminal(10, 5)
    t.write("\u{1b}[2;3H\u{1b}7\u{1b}[5;5H\u{1b}8")
    #expect(t.x == 2 && t.y == 1)
    t.write("\u{1b}[4;4H\u{1b}[s\u{1b}[H\u{1b}[u")
    #expect(t.x == 3 && t.y == 3)
  }

  @Test func eraseInLineAndDisplay() {
    let t = ShellTerminal(6, 3)
    t.write("abcdef\r\nghijkl\r\nmnopqr")
    t.write("\u{1b}[2;3H\u{1b}[K")
    #expect(text(t, 1) == "gh")
    t.write("\u{1b}[1K")
    #expect(t.line(1) == "      ")
    t.write("\u{1b}[1;4H\u{1b}[J")
    #expect(text(t, 0) == "abc")
    #expect(text(t, 2) == "")
    t.write("\u{1b}[2J")
    #expect(text(t, 0) == "")
  }

  @Test func insertAndDeleteCharacters() {
    let t = ShellTerminal(6, 1)
    t.write("abcdef\u{1b}[1;2H\u{1b}[2@")
    #expect(t.line(0) == "a  bcd")
    t.write("\u{1b}[3P")
    #expect(t.line(0) == "acd   ")
    t.write("\u{1b}[1;1H\u{1b}[2X")
    #expect(t.line(0) == "  d   ")
  }

  @Test func insertAndDeleteLines() {
    let t = ShellTerminal(3, 3)
    t.write("aaa\r\nbbb\r\nccc")
    t.write("\u{1b}[2;1H\u{1b}[L")
    #expect([text(t, 0), text(t, 1), text(t, 2)] == ["aaa", "", "bbb"])
    t.write("\u{1b}[M")
    #expect([text(t, 0), text(t, 1), text(t, 2)] == ["aaa", "bbb", ""])
  }

  @Test func scrollRegionKeepsLinesOutside() {
    let t = ShellTerminal(3, 4)
    t.write("111\r\n222\r\n333\r\n444")
    t.write("\u{1b}[2;3r")
    #expect(t.x == 0 && t.y == 0)
    t.write("\u{1b}[3;1H\n")
    #expect([text(t, 0), text(t, 1), text(t, 2), text(t, 3)] == ["111", "333", "", "444"])
    // 領域の上端で逆改行すると、領域の中だけ下へずれる。
    t.write("\u{1b}[2;1H\u{1b}M")
    #expect([text(t, 0), text(t, 1), text(t, 2), text(t, 3)] == ["111", "", "333", "444"])
    // 先頭行から流れたのではないので、スクロールバックには残さない。
    #expect(t.scrollback.isEmpty)
  }

  @Test func alternateScreenRestoresPrimaryAndSkipsScrollback() {
    let t = ShellTerminal(5, 2)
    t.write("main")
    t.write("\u{1b}[?1049h")
    #expect(text(t, 0) == "")
    #expect(t.x == 0 && t.y == 0)
    t.write("a\r\nb\r\nc\r\nd")
    #expect(t.scrollback.isEmpty)
    t.write("\u{1b}[?1049l")
    #expect(text(t, 0) == "main")
    #expect(t.x == 4 && t.y == 0)
  }

  @Test func sgrColorsAndAttributes() {
    let t = ShellTerminal(10, 1)
    t.write("\u{1b}[1;4;31ma\u{1b}[38;5;196mb\u{1b}[38;2;1;2;3;48;5;232mc\u{1b}[0md\u{1b}[7me")
    #expect(t.cell(0, 0).style.bold)
    #expect(t.cell(0, 0).style.underline)
    #expect(t.cell(0, 0).style.fg == Rgb(0xcd3131))
    #expect(t.cell(1, 0).style.fg == Rgb(0xff0000))
    #expect(t.cell(2, 0).style.fg == Rgb(0x010203))
    #expect(t.cell(2, 0).style.bg == Rgb(0x080808))
    #expect(t.cell(3, 0).style == ShellTerminal.plain)
    // 反転は前景と背景を入れ替えて塗る。
    #expect(t.cell(4, 0).style.fg == .defaultBackground)
    #expect(t.cell(4, 0).style.bg == .defaultForeground)
  }

  @Test func brightAndDefaultColors() {
    let t = ShellTerminal(10, 1)
    t.write("\u{1b}[92;104ma\u{1b}[39;49mb")
    #expect(t.cell(0, 0).style.fg == Rgb(0x23d18b))
    #expect(t.cell(0, 0).style.bg == Rgb(0x3b8eea))
    #expect(t.cell(1, 0).style.fg == .defaultForeground)
    #expect(t.cell(1, 0).style.bg == .defaultBackground)
  }

  @Test func oscHyperlinkSurvivesSgrReset() {
    let t = ShellTerminal(10, 1)
    t.write("\u{1b}]8;;https://example.com\u{1b}\\a\u{1b}[0mb\u{1b}]8;;\u{07}c")
    #expect(t.cell(0, 0).style.link == "https://example.com")
    #expect(t.cell(1, 0).style.link == "https://example.com")
    #expect(t.cell(2, 0).style.link == nil)
  }

  @Test func otherStringSequencesAndCharsetsAreIgnored() {
    let t = ShellTerminal(10, 1)
    t.write("\u{1b}]0;title\u{07}\u{1b}P1$r\u{1b}\\\u{1b}(Bok")
    #expect(text(t, 0) == "ok")
  }

  @Test func modesAreTracked() {
    let t = ShellTerminal(10, 2)
    t.write("\u{1b}[?1h\u{1b}[?2004h\u{1b}[?25l")
    #expect(t.applicationCursor)
    #expect(t.bracketedPaste)
    #expect(!t.cursorVisible)
    t.write("\u{1b}[?1l\u{1b}[?2004l\u{1b}[?25h")
    #expect(!t.applicationCursor)
    #expect(!t.bracketedPaste)
    #expect(t.cursorVisible)
  }

  @Test func insertModeShiftsText() {
    let t = ShellTerminal(5, 1)
    t.write("abc\r\u{1b}[4hX\u{1b}[4lY")
    #expect(t.line(0) == "XYbc ")
  }

  @Test func autoWrapOffOverwritesLastColumn() {
    let t = ShellTerminal(3, 2)
    t.write("\u{1b}[?7labcd")
    #expect(t.line(0) == "abd")
    #expect(t.y == 0)
  }

  @Test func resetClearsEverything() {
    let t = ShellTerminal(5, 2)
    t.write("\u{1b}[31m\u{1b}[?2004hab\u{1b}c")
    #expect(text(t, 0) == "")
    #expect(t.x == 0 && t.y == 0)
    #expect(!t.bracketedPaste)
    t.write("x")
    #expect(t.cell(0, 0).style == ShellTerminal.plain)
  }

  @Test func statusQueriesAreAnswered() {
    let t = ShellTerminal(10, 5)
    var responses: [String] = []
    t.onResponse = { responses.append($0) }
    t.write("\u{1b}[3;5H\u{1b}[6n\u{1b}[5n\u{1b}[c\u{1b}[>c")
    #expect(responses == ["\u{1b}[3;5R", "\u{1b}[0n", "\u{1b}[?1;2c", "\u{1b}[>0;0;0c"])
  }

  @Test func controlCharacters() {
    let t = ShellTerminal(20, 2)
    t.write("ab\u{08}c\tX")
    #expect(t.line(0).hasPrefix("ac      X"))
    t.write("\u{07}\u{7f}")
    #expect(t.x == 9)
  }

  @Test func sequenceSplitAcrossWrites() {
    let t = ShellTerminal(10, 2)
    t.write("\u{1b}[")
    t.write("2;")
    t.write("3Hz")
    #expect(t.cell(2, 1).text == "z")
  }

  @Test func resizeKeepsCursorLine() {
    let t = ShellTerminal(5, 4)
    t.write("1\r\n2\r\n3\r\n4")
    t.resize(3, 2)
    #expect(t.columns == 3 && t.rows == 2)
    #expect([text(t, 0), text(t, 1)] == ["3", "4"])
    #expect(t.y == 1)
  }

  @Test func resizeDropsHalfOfWideCharacterAtEdge() {
    let t = ShellTerminal(6, 1)
    t.write("abあ")
    t.resize(3, 1)
    #expect(t.line(0) == "ab ")
  }

  @Test func scrollbackIsLimited() {
    let t = ShellTerminal(5, 1)
    for _ in 0..<(ShellTerminal.scrollbackLimit + 10) {
      t.write("x\n")
    }
    #expect(t.scrollback.count == ShellTerminal.scrollbackLimit)
  }

  @Test func hugeParametersDoNotCrash() {
    let t = ShellTerminal(5, 2)
    t.write("\u{1b}[9223372036854775807C\u{1b}[-9223372036854775807A\u{1b}[-5@\u{1b}[-5P\u{1b}[-3S")
    #expect(t.x == 4)
    // Int に収まらない値は（Dart の int.tryParse と同じく）省略として扱う。
    t.write("\u{1b}[99999999999999999999999D")
    #expect(t.x == 3)
  }
}

@MainActor
struct ShellInputTests {
  @Test func convertsCursorKeysForApplicationMode() {
    let t = ShellTerminal(10, 2)
    var sent: [[UInt8]] = []
    let input = ShellInput(t, send: { sent.append($0) })
    #expect(input.filter(Array("\u{1b}[A".utf8)).isEmpty)
    t.write("\u{1b}[?1h")
    _ = input.filter(Array("\u{1b}[Bx".utf8))
    #expect(sent == [Array("\u{1b}[A".utf8), Array("\u{1b}OBx".utf8)])
  }

  @Test func forwardsPasteMarkersOnlyWhenEnabled() {
    let t = ShellTerminal(10, 2)
    var sent: [[UInt8]] = []
    let input = ShellInput(t, send: { sent.append($0) })
    _ = input.filter(Array("\u{1b}[200~\u{1b}[Aa\u{1b}[201~".utf8))
    // 貼り付けの中の矢印は変換しない。
    #expect(sent == [Array("\u{1b}[Aa".utf8)])
    sent.removeAll()
    t.write("\u{1b}[?2004h")
    _ = input.filter(Array("\u{1b}[200~b\u{1b}[201~".utf8))
    #expect(sent == [Array("\u{1b}[200~b\u{1b}[201~".utf8)])
  }
}
