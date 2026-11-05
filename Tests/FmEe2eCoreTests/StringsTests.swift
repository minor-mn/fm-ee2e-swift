import Foundation
import Testing

@testable import FmEe2eCore

/// リポジトリの一番上のフォルダー。
private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
struct StringsTests {
  @Test("languages/ja.json5 を読めて、コードで使っている文言の名前がすべてある")
  func everyKeyExists() throws {
    let table = try Strings.parse(try Data(contentsOf: repoRoot.appending(path: "fm-ee2e/languages/ja.json5")))
    let pattern = try NSRegularExpression(pattern: #"\btr\(\s*(?:[a-z]+ \? )?"([a-z_.]+)"(?: : "([a-z_.]+)")?"#)
    var used: Set<String> = []
    let sources = FileManager.default.enumerator(at: repoRoot.appending(path: "Sources"), includingPropertiesForKeys: nil)!
    for case let url as URL in sources where url.pathExtension == "swift" {
      let text = try String(contentsOf: url, encoding: .utf8)
      for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        for group in 1..<match.numberOfRanges {
          if let range = Range(match.range(at: group), in: text) {
            used.insert(String(text[range]))
          }
        }
      }
    }
    #expect(used.count > 300)
    #expect(used.subtracting(table.keys).sorted() == [])
  }

  @Test("languages/en.json5 は ja.json5 と同じ名前を持ち、同じ {name} を使う")
  func englishMatchesJapanese() throws {
    let ja = try Strings.parse(try Data(contentsOf: repoRoot.appending(path: "fm-ee2e/languages/ja.json5")))
    let en = try Strings.parse(try Data(contentsOf: repoRoot.appending(path: "fm-ee2e/languages/en.json5")))
    #expect(Set(en.keys) == Set(ja.keys))
    let placeholder = try NSRegularExpression(pattern: #"\{[a-z_]+\}"#)
    func names(_ text: String) -> Set<String> {
      Set(placeholder.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) })
    }
    for (key, text) in ja {
      #expect(names(en[key] ?? "") == names(text), "\(key)")
    }
  }

  @Test("入れ子の名前は「.」でつなぎ、配列は改行でつなぎ、{name} は値にする")
  func parseAndReplace() throws {
    let data = Data(
      ##"""
      {
        a: {
          b: "「{name}」を{count}件",
          lines: [
            "1行目",
            "2行目",
          ],
        },
      }
      """##.utf8
    )
    let table = try Strings.parse(data)
    #expect(table["a.lines"] == "1行目\n2行目")
    let saved = Strings.table
    defer {
      Strings.table = saved
    }
    Strings.table = table
    #expect(tr("a.b", ["name": "x.png", "count": 3]) == "「x.png」を3件")
    #expect(tr("a.none") == "a.none")
    #expect(throws: ConfigFormatError.self) { try Strings.parse(Data("{ a: 1 }".utf8)) }
  }

  @Test("古い利用者設定で欠けた文言を同梱データで補い、利用者の変更を優先する")
  func bundledDefaults() throws {
    let saved = Strings.table
    defer { Strings.table = saved }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fm-strings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("en.json5")
    let defaults = Data(#"{pane:{loading:"Loading"},container:{start:"Start"}}"#.utf8)
    try Data(#"{pane:{loading:"Custom loading"}}"#.utf8).write(to: file)
    #expect(Strings.loadFile(file.path, fallback: defaults) == nil)
    #expect(tr("pane.loading") == "Custom loading")
    #expect(tr("container.start") == "Start")
    try Data("invalid".utf8).write(to: file)
    #expect(Strings.loadFile(file.path, fallback: defaults) != nil)
    #expect(tr("pane.loading") == "Custom loading")
    try FileManager.default.removeItem(at: file)
    #expect(Strings.loadFile(file.path, fallback: defaults) == nil)
    #expect(tr("pane.loading") == "Loading")
  }
}
