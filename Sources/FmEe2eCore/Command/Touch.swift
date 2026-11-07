import Foundation

/// 名前を聞いて touch する（T・F5）。なければ空のファイルを作り、あれば更新日時を今にする。
/// 名前を聞く小窓と流れはここに書き、touch のしかたはタブごとの継承クラスに書く。
class TouchCommand: Command {
  override var label: String { "Touch" }

  override var writes: Bool { true }

  /// 開いているフォルダーの [name] を touch する。
  func touch(_ c: CommandContext, _ name: String) async throws { fatalError("touch") }

  override func run(_ c: CommandContext) async {
    await applyName(c.pane, await askName(c.app, "touch", message: tr("touch.message"))) { name in try await self.touch(c, name) }
  }
}

final class LocalTouch: TouchCommand {
  /// 「-」で始まる名前をオプションと誤認させないよう、絶対パスで渡す。
  override func touch(_ c: CommandContext, _ name: String) async throws {
    try await runOrThrow("/usr/bin/touch", [p.join(p.absolute((c.pane as! LocalPane).dir), name)])
  }
}

/// 同じ名前（復号した名前）があれば、その更新日時を今にする。なければ、空のファイルを暗号化して置く。
final class DriveTouch: TouchCommand {
  override func touch(_ c: CommandContext, _ name: String) async throws {
    let pane = c.pane as! DrivePane
    let dir = pane.dirPath
    switch try await pane.itemsIn(dir)[name] {
    case let file as LocalFile:
      try await runOrThrow("/usr/bin/touch", [file.file])
    case let folder as LocalDir:
      try await runOrThrow("/usr/bin/touch", [folder.directory])
    default:
      let temp = try makeTempDir("fm-ee2e-touch-")
      defer {
        try? FileManager.default.removeItem(atPath: temp)
      }
      let empty = p.join(temp, "empty")
      FileManager.default.createFile(atPath: empty, contents: nil)
      let to = try await pane.place(dir, name, isFolder: false) { try await pane.encryptFile(empty, $0) }
      // 手元には残さない（Drive に上がり終えたら外す）。
      pane.evictLater([to])
    }
  }
}

final class SshTouch: TouchCommand {
  override func touch(_ c: CommandContext, _ name: String) async throws {
    let pane = c.pane as! SshPane
    try await pane.ssh!.touch(PathContext.posix.join(pane.dir, name))
  }
}
