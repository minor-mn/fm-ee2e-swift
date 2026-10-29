import Foundation

/// 名前を聞いて、開いているフォルダーにフォルダーを作る（K・F6）。
/// 名前を聞く小窓と流れはここに書き、同名の確認に使う名前の一覧と、作り方はタブごとの継承クラスに書く。
class MkdirCommand: Command {
  override var label: String { "Mkdir" }

  override var writes: Bool { true }

  /// 開いているフォルダーにある名前（同名の確認に使う）。
  func existingNames(_ c: CommandContext) async throws -> Set<String> { fatalError("existingNames") }

  /// [name] のフォルダーを作る。
  func create(_ c: CommandContext, _ name: String) async throws { fatalError("create") }

  /// 作ったあと。ふつうは作ったフォルダーにカーソルを合わせて読み直す。
  func afterCreate(_ c: CommandContext, _ name: String) async { await c.pane.load(focus: name) }

  override func run(_ c: CommandContext) async {
    let existing: Set<String>
    do {
      existing = try await existingNames(c)
    } catch {
      await c.app.showError(error)
      return
    }
    guard let name = await askName(c.app, "新しいフォルダー", message: "フォルダー名", existing: existing) else {
      return
    }
    do {
      try await create(c, name)
    } catch {
      await c.app.showError(error)
    }
    await afterCreate(c, name)
  }
}

final class LocalMkdir: MkdirCommand {
  override func existingNames(_ c: CommandContext) async throws -> Set<String> {
    try await dirNames((c.pane as! LocalPane).dir)
  }

  override func create(_ c: CommandContext, _ name: String) async throws {
    try createDirectory(p.join((c.pane as! LocalPane).dir, name))
  }
}

final class SshMkdir: MkdirCommand {
  /// 一覧を読んだときの名前（隠しファイルを含む）。
  override func existingNames(_ c: CommandContext) async throws -> Set<String> { (c.pane as! SshPane).names }

  override func create(_ c: CommandContext, _ name: String) async throws {
    let pane = c.pane as! SshPane
    try await pane.ssh!.mkdir(PathContext.posix.join(pane.dir, name))
  }
}

/// 名前を暗号化したフォルダーを作る。
final class DriveMkdir: MkdirCommand {
  /// 開いているフォルダーの、復号した名前。
  override func existingNames(_ c: CommandContext) async throws -> Set<String> {
    let pane = c.pane as! DrivePane
    return Set(try await pane.itemsIn(pane.dirPath).keys)
  }

  override func create(_ c: CommandContext, _ name: String) async throws {
    let pane = c.pane as! DrivePane
    try createDirectory(try await pane.encryptedPath(pane.dirPath, name, isFolder: true))
  }
}

/// Dart の Directory.create() と同じく、すでにフォルダーがあれば何もしない。
private func createDirectory(_ path: String) throws {
  var isDir: ObjCBool = false
  if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue {
    return
  }
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
}
