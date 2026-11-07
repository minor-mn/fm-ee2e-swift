import Foundation
import Testing

@testable import FmEe2eCore

@MainActor
struct LocationHistoryTests {
  @Test func remembersPerKeyWithoutDuplicatesAndLimit() throws {
    let dir = try makeTempDir("fm-ee2e-history-test-")
    defer {
      try? FileManager.default.removeItem(atPath: dir)
    }
    let file = p.join(dir, "sub", "location_history.json")
    #expect(LocationHistory.load("local", file: file).isEmpty)
    try LocationHistory.remember("local", "/a", file: file)
    try LocationHistory.remember("local", "/b", file: file)
    try LocationHistory.remember("ssh:host", "/srv", file: file)
    // 同じパスは新しいほうへ寄せる。
    try LocationHistory.remember("local", "/a", file: file)
    #expect(LocationHistory.load("local", file: file) == ["/b", "/a"])
    #expect(LocationHistory.load("ssh:host", file: file) == ["/srv"])
    for i in 0..<(LocationHistory.limit + 5) {
      try LocationHistory.remember("local", "/d\(i)", file: file)
    }
    let list = LocationHistory.load("local", file: file)
    #expect(list.count == LocationHistory.limit)
    #expect(list.last == "/d\(LocationHistory.limit + 4)")
  }

  @Test func unchangedInitialTextBrowsesWholeHistory() {
    let dialog = InputDialog("go", { _ in }, initial: "/a/b", history: ["/x", "/a/b/c", "/a/b"])
    let up = Key.named("up")
    let down = Key.named("down")
    // 今のフォルダー（開いたときの文字）と同じものは飛ばし、絞り込まずにさかのぼる。
    dialog.handleKey(up)
    #expect(dialog.field.value == "/a/b/c")
    dialog.handleKey(up)
    #expect(dialog.field.value == "/x")
    dialog.handleKey(down)
    dialog.handleKey(down)
    // たどる前の文字に戻り、カーソルは末尾。
    #expect(dialog.field.value == "/a/b")
    #expect(dialog.field.afterCursor.isEmpty)
  }

  @Test func editedTextNarrowsHistoryByPrefix() {
    let dialog = InputDialog("go", { _ in }, initial: "", history: ["/x/1", "/a/1", "/x/2"])
    dialog.handleKey(.char("/"))
    dialog.handleKey(.char("a"))
    dialog.handleKey(.named("up"))
    #expect(dialog.field.value == "/a/1")
  }
}
