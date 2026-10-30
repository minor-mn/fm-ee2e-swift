/// 対象を消す（D・F4・Del）。確かめる小窓と流れはここに書き、文言と消し方はタブごとの継承クラスに書く。
class DeleteCommand: Command {
  override var label: String { "Delete" }

  override var writes: Bool { true }

  /// 確かめる小窓の見出し。
  var title: String { fatalError("title") }

  /// 確かめる小窓の本文。[label] は消す項目（「「名前」」か「N項目」）。
  func message(_ c: CommandContext, _ label: String) -> String { fatalError("message") }

  /// 実行するボタンの文言。
  var yes: String { fatalError("yes") }

  /// 消している間に出す文言。
  var progress: String { fatalError("progress") }

  /// [targets] を消す。
  func remove(_ c: CommandContext, _ targets: [Mark]) async throws { fatalError("remove") }

  override func run(_ c: CommandContext) async {
    let targets = c.targets
    if targets.isEmpty {
      return
    }
    if !(await c.app.confirm(title, message(c, quotedLabel(targets)), yes: yes)) {
      return
    }
    do {
      try await c.app.withProgress(progress) { try await self.remove(c, targets) }
    } catch {
      await c.app.showError(error)
    }
    c.pane.marks.clear()
    await c.pane.load()
  }
}

/// ゴミ箱へ移す。
final class LocalDelete: DeleteCommand {
  override var title: String { tr("delete.trash_title") }

  override func message(_ c: CommandContext, _ label: String) -> String { tr("delete.trash_confirm", ["label": label]) }

  override var yes: String { tr("delete.trash_yes") }

  override var progress: String { tr("delete.trash_progress") }

  override func remove(_ c: CommandContext, _ targets: [Mark]) async throws {
    let pane = c.pane as! LocalPane
    for mark in targets {
      try await moveToTrash(pane.pathOfMark(mark))
    }
  }
}

/// ゴミ箱はないので、そのまま消す。
final class SshDelete: DeleteCommand {
  override var title: String { tr("delete.ssh_title") }

  override func message(_ c: CommandContext, _ label: String) -> String {
    tr("delete.ssh_confirm", ["label": label, "host": (c.pane as! SshPane).ssh!.host])
  }

  override var yes: String { tr("delete.ssh_yes") }

  override var progress: String { tr("delete.ssh_progress") }

  override func remove(_ c: CommandContext, _ targets: [Mark]) async throws {
    let pane = c.pane as! SshPane
    try await pane.ssh!.remove(targets.map { pane.pathOfMark($0) })
  }
}

/// ゴミ箱へ移す（Google Drive のゴミ箱に入る）。
final class DriveDelete: DeleteCommand {
  override var title: String { tr("delete.trash_title") }

  override func message(_ c: CommandContext, _ label: String) -> String { tr("delete.trash_confirm", ["label": label]) }

  override var yes: String { tr("delete.trash_yes") }

  override var progress: String { tr("delete.trash_progress") }

  override func remove(_ c: CommandContext, _ targets: [Mark]) async throws {
    let pane = c.pane as! DrivePane
    for mark in targets {
      try await moveToTrash(pane.pathOfMark(mark))
    }
  }
}
