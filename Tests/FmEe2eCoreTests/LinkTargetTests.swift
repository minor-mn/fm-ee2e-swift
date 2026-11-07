import Foundation
import Testing

@testable import FmEe2eCore

/// 上の帯の Mode の右に出す、シンボリックリンクの指している先。
@MainActor
struct LinkTargetTests {
  @Test func showsWhatTheLinkPointsTo() throws {
    let dir = try makeTempDir("fm-ee2e-link-test-")
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.createDirectory(atPath: p.join(dir, "target"), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: p.join(dir, "target", "file.txt"), contents: Data())
    // 相対のリンクは、リンクのフォルダーから見た絶対パスにする。リンクを指すリンクは、その先のリンクまで（たどらない）。
    try FileManager.default.createSymbolicLink(atPath: p.join(dir, "link"), withDestinationPath: "target/file.txt")
    try FileManager.default.createSymbolicLink(atPath: p.join(dir, "link2"), withDestinationPath: "link")
    try FileManager.default.createSymbolicLink(atPath: p.join(dir, "abs"), withDestinationPath: "/etc/hosts")
    #expect(symlinkTarget(p.join(dir, "link")) == p.join(dir, "target", "file.txt"))
    #expect(symlinkTarget(p.join(dir, "link2")) == p.join(dir, "link"))
    #expect(symlinkTarget(p.join(dir, "abs")) == "/etc/hosts")
    // リンクでなければ出さない。
    #expect(symlinkTarget(p.join(dir, "target")) == nil)
  }

  @Test func brokenLinkShowsWhereItPoints() throws {
    let dir = try makeTempDir("fm-ee2e-link-test-")
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.createSymbolicLink(atPath: p.join(dir, "broken"), withDestinationPath: "../missing")
    #expect(symlinkTarget(p.join(dir, "broken")) == p.join(p.dirname(dir), "missing"))
  }

  @Test func remoteListKeepsLinkTarget() {
    let ls = """
      total 0
      lrwxrwxrwx 1 me me 12 Oct 28 06:50 current -> releases/42
      lrwxrwxrwx 1 me me  9 Oct 28 06:50 a -> b -> c -> /etc/hosts
      -rw-r--r-- 1 me me  0 Oct 28 06:50 plain
      """
    var out = Data(ls.utf8)
    out.append(0)
    out.append(Data("dcurrent\0fa -> b\0fplain\0".utf8))
    let entries = parseRemoteList(out, Date())
    #expect(entries.first { $0.name == "current" }?.linkTarget == "releases/42")
    // 名前に「 -> 」が入っていても、知っている名前で切った残りが先になる。
    #expect(entries.first { $0.name == "a -> b" }?.linkTarget == "c -> /etc/hosts")
    #expect(entries.first { $0.name == "plain" }?.linkTarget == nil)
  }

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

  private final class OwnershipPane: Pane {
    init(_ ownership: Ownership) {
      self.ownership = ownership
      super.init(App(TestHost()))
      entries = [Entry(name: "link", isDir: false, data: ())]
    }

    let ownership: Ownership
    override func ownershipOf(_ entry: Entry) -> Ownership? { ownership }
  }

  private func ownershipLine(_ ownership: Ownership) -> String {
    let screen = Screen(80, 1)
    drawOwnership(screen, 0, OwnershipPane(ownership))
    return (0..<80).map { screen.cell($0, 0)?.text ?? " " }.joined().trimmingCharacters(in: .whitespaces)
  }

  @Test func headerShowsLinkTargetOneCellAfterMode() {
    #expect(ownershipLine(Ownership("me", "staff", "lrwxr-xr-x", linkTarget: "/opt/real")) == "Owner me   Group staff   Mode lrwxr-xr-x /opt/real")
    #expect(ownershipLine(Ownership("me", "staff", "-rw-r--r--")) == "Owner me   Group staff   Mode -rw-r--r--")
  }
}
