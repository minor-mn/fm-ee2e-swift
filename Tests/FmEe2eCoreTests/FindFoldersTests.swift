import Foundation
import Testing

@testable import FmEe2eCore

/// 名前で探すときは、名前の合うフォルダーも結果に出す。中身で探すときはファイルだけ。
struct FindFoldersTests {
  private func makeTree() throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fm-find-" + UUID().uuidString).path
    for dir in [".fm-ee2e/containers", "vendor/.fm-ee2e", "src"] {
      try FileManager.default.createDirectory(atPath: p.join(root, dir), withIntermediateDirectories: true)
    }
    try "x".write(toFile: p.join(root, ".fm-ee2e/project.json5"), atomically: true, encoding: .utf8)
    try "fm-ee2e".write(toFile: p.join(root, "src/a.fm-ee2e.txt"), atomically: true, encoding: .utf8)
    return root
  }

  private func query(_ root: String, names: [String], content: String = "") -> FindQuery {
    FindQuery(root: root, content: content, names: names, extensions: [], ignored: ["vendor"])
  }

  private func relative(_ items: [FoundItem], _ root: String) -> [String] {
    items.map { String($0.path.dropFirst(root.count + 1)) + ($0.isDir ? "/" : "") }.sorted()
  }

  @Test("ローカル: 名前で探すとフォルダーも出る（無視するフォルダーの中は探さない）")
  func local() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(atPath: root) }
    #expect(relative(try findFiles(query(root, names: [".fm-ee2e"])), root) == [".fm-ee2e/", "src/a.fm-ee2e.txt"])
    #expect(relative(try findFiles(query(root, names: [".fm-ee2e"], content: "fm")), root) == ["src/a.fm-ee2e.txt"])
    #expect(refindFiles([p.join(root, ".fm-ee2e")], query(root, names: [".fm-ee2e"])).first?.isDir == true)
  }

  @Test("接続先: find のスクリプトでもフォルダーが出る")
  func remote() async throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let q = query(root, names: [".fm-ee2e"])
    let result = try await runProcess("/bin/sh", ["-c", remoteFindScript(q)])
    let items = try #require(parseRemoteFound(result.stdoutData, q))
    #expect(relative(items, root) == [".fm-ee2e/", "src/a.fm-ee2e.txt"])
  }

  @Test("中身: ^ $ は各行に合う（ファイル全体で先に照らしても落とさない）")
  func anchors() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try "first\nsecond line\nthird\n".write(toFile: p.join(root, "src/lines.txt"), atomically: true, encoding: .utf8)
    let items = try findFiles(FindQuery(root: root, content: "^second.*$", names: [], extensions: [], ignored: []))
    #expect(items.map { p.basename($0.path) } == ["lines.txt"])
    #expect(items.first?.lines.contains { $0.matched && $0.number == 2 } == true)
    #expect(try findFiles(FindQuery(root: root, content: "first\\nsecond", names: [], extensions: [], ignored: [])).isEmpty)
  }

  @Test("先頭が UTF-8 でないファイルは中身を見ない")
  func textProbe() {
    #expect(looksLikeText(Data("abc あいう".utf8), truncated: false))
    // 途中で切れた「あ」（3バイトのうち2バイト）。
    #expect(looksLikeText(Data("abc".utf8) + Data([0xE3, 0x81]), truncated: true))
    #expect(!looksLikeText(Data("abc".utf8) + Data([0xE3, 0x81]), truncated: false))
    // Shift_JIS の「あ」。
    #expect(!looksLikeText(Data([0x82, 0xA0, 0x41]), truncated: false))
    #expect(!looksLikeText(Data([0x41, 0x00, 0x42]), truncated: false))
  }
}
