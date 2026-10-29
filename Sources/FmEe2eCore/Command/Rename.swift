/// 対象の1項目の名前を変える（R・F7）。名前を聞く小窓と流れはここに書き、
/// 同名の確認に使う名前の一覧と、名前の変え方はタブごとの継承クラスに書く。
class RenameCommand: Command {
  override var label: String { "Rename" }

  override var writes: Bool { true }

  override var single: Bool { true }

  /// [target] と同じフォルダーにある名前（同名の確認に使う）。
  func siblingNames(_ c: CommandContext, _ target: Mark) async throws -> Set<String> { fatalError("siblingNames") }

  /// [target] の名前を [name] に変える。
  func rename(_ c: CommandContext, _ target: Mark, _ name: String) async throws { fatalError("rename") }

  override func run(_ c: CommandContext) async {
    guard let target = c.targets.first else {
      return
    }
    let current = target.entry.name
    let existing: Set<String>
    do {
      existing = try await siblingNames(c, target).subtracting([current])
    } catch {
      await c.app.showError(error)
      return
    }
    // 拡張子の前までを選択した状態で開く。
    let name = await askName(c.app, "名前を変更", initial: current, selectStem: true, existing: existing)
    if name == current {
      return
    }
    await applyName(c.pane, name) { name in try await self.rename(c, target, name) }
  }
}

final class LocalRename: RenameCommand {
  /// 隠しファイルを表示していないときも衝突させないよう、実際のフォルダーの中身で確認する。
  override func siblingNames(_ c: CommandContext, _ target: Mark) async throws -> Set<String> {
    try await dirNames(target.parent)
  }

  override func rename(_ c: CommandContext, _ target: Mark, _ name: String) async throws {
    try await movePath((c.pane as! LocalPane).pathOfMark(target), p.join(target.parent, name))
  }
}

final class SshRename: RenameCommand {
  /// 一覧に出していない隠しファイルも含め、接続先のフォルダーを読み直して確認する。
  override func siblingNames(_ c: CommandContext, _ target: Mark) async throws -> Set<String> {
    Set(try await (c.pane as! SshPane).ssh!.list(target.parent).map { $0.name })
  }

  override func rename(_ c: CommandContext, _ target: Mark, _ name: String) async throws {
    let pane = c.pane as! SshPane
    try await pane.ssh!.move(pane.pathOfMark(target), PathContext.posix.join(target.parent, name))
  }
}

/// 名前を暗号化し直して（ファイルは拡張子より前、フォルダーは全体）、暗号化した名前どうしで変える。中身はそのまま。
final class DriveRename: RenameCommand {
  /// 同じフォルダーの、復号した名前。
  override func siblingNames(_ c: CommandContext, _ target: Mark) async throws -> Set<String> {
    Set(try await (c.pane as! DrivePane).itemsIn(target.parent).keys)
  }

  override func rename(_ c: CommandContext, _ target: Mark, _ name: String) async throws {
    let pane = c.pane as! DrivePane
    try await movePath(
      pane.pathOfMark(target),
      try await pane.encryptedPath(target.parent, name, isFolder: target.entry.isDir)
    )
  }
}
