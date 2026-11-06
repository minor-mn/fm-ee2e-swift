import Foundation
import Testing

@testable import FmEe2eCore

@MainActor
struct InputFieldTests {
  private func left(shift: Bool = false) -> Key { .named("left", shift: shift) }
  private func right(shift: Bool = false) -> Key { .named("right", shift: shift) }

  /// [field] を幅 [width] に描いたときに見える文字（末尾の空白を除く）と、カーソルの桁。
  private func drawn(_ field: InputField, _ width: Int) -> (String, Int?) {
    let screen = Screen(width, 1)
    field.draw(screen, 0, 0, width)
    var text = ""
    var x = 0
    while x < width {
      let cell = screen.cell(x, 0)
      let shown = cell?.text ?? " "
      text += shown
      x += max(textWidth(shown), 1)
    }
    while text.hasSuffix(" ") {
      text.removeLast()
    }
    return (text, screen.cursor?.x)
  }

  @Test func selectStemSelectsUpToExtension() {
    let field = InputField(initial: "report.pdf", selectStem: true)
    #expect(field.selectedText == "report")
    field.handleKey(.char("x"))
    #expect(field.value == "x.pdf")
  }

  @Test func selectAllAndCopy() {
    let field = InputField(initial: "とても長い名前.txt")
    field.handleKey(.named("selectAll"))
    #expect(field.selectedText == "とても長い名前.txt")
    field.handleKey(.named("backspace"))
    #expect(field.value == "")
  }

  @Test func shiftArrowsExtendAndShrinkSelection() {
    let field = InputField(initial: "abcdef")
    field.handleKey(.named("home"))
    field.handleKey(right())
    field.handleKey(right(shift: true))
    field.handleKey(right(shift: true))
    field.handleKey(right(shift: true))
    #expect(field.selectedText == "bcd")
    field.handleKey(left(shift: true))
    #expect(field.selectedText == "bc")
    // 起点を越えて戻ると、反対側を選ぶ。
    field.handleKey(left(shift: true))
    field.handleKey(left(shift: true))
    field.handleKey(left(shift: true))
    #expect(field.selectedText == "a")
    field.handleKey(.named("end", shift: true))
    #expect(field.selectedText == "bcdef")
    field.handleKey(.named("home", shift: true))
    #expect(field.selectedText == "a")
  }

  @Test func plainArrowsCollapseToSelectionEdge() {
    let field = InputField(initial: "abcdef")
    field.handleKey(.named("selectAll"))
    field.handleKey(left())
    #expect(field.selectedText == nil && field.cursor == 0)
    field.handleKey(.named("selectAll"))
    field.handleKey(right())
    #expect(field.selectedText == nil && field.cursor == 6)
  }

  @Test func typingAndPasteReplaceSelection() {
    let field = InputField(initial: "abcdef")
    field.handleKey(.named("home"))
    field.handleKey(right())
    field.handleKey(right(shift: true))
    field.handleKey(right(shift: true))
    field.handleKey(.paste("XY"))
    #expect(field.value == "aXYdef")
    field.handleKey(left(shift: true))
    field.handleKey(.named("delete"))
    #expect(field.value == "aXdef")
  }

  @Test func maskedFieldDoesNotCopy() {
    let field = InputField(initial: "secret", masked: true)
    field.handleKey(.named("selectAll"))
    #expect(field.selectedText == nil)
  }

  @Test func scrollsOnlyAsFarAsNeeded() {
    let field = InputField(initial: "0123456789")
    // 末尾にカーソル。幅5ではカーソルの分を空けて末尾の4文字が見える。
    #expect(drawn(field, 5) == ("6789", 4))
    // 左へ動かしても、見えている間は流さない。
    for _ in 0..<3 {
      field.handleKey(left())
    }
    #expect(drawn(field, 5) == ("6789", 1))
    // 左端を越えたら、そのぶんだけ流す。
    field.handleKey(left())
    field.handleKey(left())
    #expect(drawn(field, 5) == ("56789", 0))
    field.handleKey(.named("home"))
    #expect(drawn(field, 5) == ("01234", 0))
    // Shift+→ で選びながら右端を越えると、右へ流す。
    for _ in 0..<7 {
      field.handleKey(right(shift: true))
    }
    #expect(drawn(field, 5) == ("34567", 4))
    #expect(field.selectedText == "0123456")
  }

  @Test func scrollsBackWhenTextShrinks() {
    let field = InputField(initial: "0123456789")
    _ = drawn(field, 5)
    for _ in 0..<3 {
      field.handleKey(.named("backspace"))
    }
    // 右に空いたぶん、左に戻して埋める。
    #expect(drawn(field, 5) == ("3456", 4))
  }
}

@MainActor
struct KeyDecoderTests {
  private func decode(_ text: String) -> [Key] {
    let decoder = KeyDecoder()
    var keys: [Key] = []
    decoder.keys.listen { keys.append($0) }
    decoder.feed(Array(text.utf8))
    return keys
  }

  @Test func decodesShiftedMoves() {
    let keys = decode("\u{1b}[1;2D\u{1b}[1;2C\u{1b}[1;2H\u{1b}[1;2F\u{1b}[D")
    #expect(keys.map(\.name) == ["left", "right", "home", "end", "left"])
    #expect(keys.map(\.shift) == [true, true, true, true, false])
  }
}
