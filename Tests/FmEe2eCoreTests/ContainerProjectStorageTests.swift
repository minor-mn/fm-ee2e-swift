import Foundation
import Testing

@testable import FmEe2eCore

/// 作成設定は ~/.config/fm-ee2e/containers/<名前>.json5 に置く。HOME を一時フォルダーに替えて確かめる。
@Suite(.serialized)
struct ContainerProjectStorageTests {
  private func withTemporaryHome(_ body: (_ home: String, _ root: String) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("fm-test-" + UUID().uuidString).path
    let home = p.join(base, "home")
    let root = p.join(base, "project")
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: p.join(root, ".fm-ee2e", "containers"), withIntermediateDirectories: true)
    let original = ProcessInfo.processInfo.environment["HOME"]!
    setenv("HOME", home, 1)
    defer {
      setenv("HOME", original, 1)
      try? FileManager.default.removeItem(atPath: base)
    }
    try body(home, root)
  }

  private func definition(_ service: String, _ name: String) -> String {
    """
    {
      create: ["create", "--name", "\(name)", "busybox"],
      image: "busybox",
      name: "\(name)",
      notes: [],
      prepare: [],
      service: "\(service)",
    }
    """
  }

  @Test("以前の形のプロジェクトは、名前で ~/.config に写して一覧を名前に書き換える")
  func migratesLegacy() throws {
    try withTemporaryHome { home, root in
      try definition("app", "app").write(toFile: p.join(root, ".fm-ee2e", "containers", "app.json5"), atomically: true, encoding: .utf8)
      try definition("redis", "career-redis").write(toFile: p.join(root, ".fm-ee2e", "containers", "redis.json5"), atomically: true, encoding: .utf8)
      try #"{containers: ["app.json5", "redis.json5"], aws_profile: "dev"}"#.write(toFile: NativeContainerProject.settings(root), atomically: true, encoding: .utf8)
      // 共通のコンテナの設定がすでにあれば、そちらを残す。
      try FileManager.default.createDirectory(atPath: NativeContainerProject.containersDirectory, withIntermediateDirectories: true)
      let shared = definition("cache", "career-redis")
      try shared.write(toFile: NativeContainerProject.definitionFile("career-redis"), atomically: true, encoding: .utf8)

      let project = try NativeContainerProject.read(root)
      #expect(project.definitions.map(\.name) == ["app", "career-redis"])
      #expect(project.definitions.map(\.service) == ["app", "cache"])
      #expect(project.awsProfile == "dev")
      #expect(NativeContainerProject.definitionFile("app") == p.join(home, ".config", "fm-ee2e", "containers", "app.json5"))
      #expect(FileManager.default.fileExists(atPath: NativeContainerProject.definitionFile("app")))
      let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: NativeContainerProject.settings(root))), options: [.json5Allowed]) as? [String: Any]
      #expect(saved?["containers"] as? [String] == ["app", "career-redis"])
      // 古いファイルは残す。
      #expect(FileManager.default.fileExists(atPath: p.join(root, ".fm-ee2e", "containers", "app.json5")))
    }
  }

  @Test("プロジェクトにないコンテナの設定も名前で引ける")
  func savedDefinitionByName() throws {
    try withTemporaryHome { _, _ in
      try FileManager.default.createDirectory(atPath: NativeContainerProject.containersDirectory, withIntermediateDirectories: true)
      try definition("redis", "redis").write(toFile: NativeContainerProject.definitionFile("redis"), atomically: true, encoding: .utf8)
      #expect(NativeContainerProject.savedDefinition("redis")?.image == "busybox")
      #expect(NativeContainerProject.savedDefinition("missing") == nil)
      #expect(NativeContainerProject.savedDefinition("../redis") == nil)
    }
  }
}
