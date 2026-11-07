import Foundation
import Testing

@testable import FmEe2eCore

/// 窓の案内（Google ドライブ for デスクトップのインストール案内など）に出す URL が、クリックで開けるリンクになるか。
@MainActor
struct PlaceholderLinkTests {
  private final class TestHost: FmEe2eCore.Host {
    let keys = Broadcast<Key>()
    let resizes = Broadcast<Void>()
    var width = 80
    var height = 24
    var inputFilter: (([UInt8]) -> [UInt8])?
    var focusedField: (() -> InputField?)?
    var sizer: GridSizer? { nil }
    func present(_ screen: Screen) {}
  }

  private final class PlaceholderPane: Pane {
    init(_ lines: [String]) {
      self.lines = lines
      super.init(App(TestHost()))
    }

    let lines: [String]
    override var placeholder: [String]? { lines }
  }

  /// 幅 [width] の窓に [lines] を描き、行ごとの（文字, リンク先）を返す。
  private func draw(_ lines: [String], width: Int) -> [[(String, String?)]] {
    let screen = Screen(width + 2, 10)
    PlaceholderPane(lines).drawBody(screen, 0, 0, width, 10, focused: true)
    return (0..<10).map { y in
      (0..<(width + 2)).compactMap { x in screen.cell(x, y).map { ($0.text, $0.style.link) } }
    }
  }

  @Test func urlLineBecomesLink() {
    let url = "https://ipv4.google.com/intl/ja/drive/download/"
    let rows = draw(["インストールしてください", url], width: 70)
    #expect(rows[0].allSatisfy { $0.1 == nil })
    let linked = rows[1].filter { $0.1 != nil }
    #expect(linked.map(\.0).joined() == url)
    #expect(linked.allSatisfy { $0.1 == url })
  }

  @Test func wrappedUrlOpensWholeUrl() {
    let url = "https://ipv4.google.com/intl/ja/drive/download/"
    // 枠の幅が狭く、URL が2行に折り返される。
    let rows = draw([url], width: 22)
    let linked = rows.flatMap { $0 }.filter { $0.1 != nil }
    #expect(linked.map(\.0).joined() == url)
    #expect(linked.allSatisfy { $0.1 == url })
    #expect(rows[1].contains { $0.1 == url })
  }
}
