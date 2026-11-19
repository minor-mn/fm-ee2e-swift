import Foundation

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
      try Task.checkCancellation()
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

/// ゴミ箱へ移す（Google Drive のゴミ箱に入る）。名前ファイルがあれば一緒に移す。
final class DriveDelete: DeleteCommand {
  override var title: String { tr("delete.trash_title") }

  override func message(_ c: CommandContext, _ label: String) -> String { tr("delete.trash_confirm", ["label": label]) }

  override var yes: String { tr("delete.trash_yes") }

  override var progress: String { tr("delete.trash_progress") }

  override func remove(_ c: CommandContext, _ targets: [Mark]) async throws {
    let pane = c.pane as! DrivePane
    for mark in targets {
      try await pane.trash(pane.pathOfMark(mark))
    }
  }
}

/// Git のタブで、ファイルの行（マークがあればマーク）のファイル・フォルダーを消す。
/// 左がローカルならゴミ箱へ移し、SSH ならそのまま消す。もうないファイル（deleted など）と、同じファイルの2行目は飛ばす。
final class GitDelete: Command {
  override var label: String { "Delete" }

  override var writes: Bool { true }

  private func ssh(_ c: CommandContext) -> Ssh? { (c.pane as! GitPane).ssh }

  /// 対象のファイルの行の、ファイルのパス（重なりを除く）。Git のタブのマークは、リポジトリの一番上のフォルダーを親にしている。
  private func paths(_ c: CommandContext) -> [String] {
    var seen = Set<String>()
    return c.targets.compactMap { mark -> String? in
      guard let line = mark.entry.data as? GitStatusLine, line.kind == .file else { return nil }
      let path = (ssh(c) == nil ? p.join(mark.parent, line.path) : PathContext.posix.join(mark.parent, line.path))
      return seen.insert(path).inserted ? path : nil
    }
  }

  override func run(_ c: CommandContext) async {
    let remote = ssh(c)
    var targets = paths(c)
    if remote == nil {
      targets = targets.filter { FileManager.default.fileExists(atPath: $0) || (try? FileManager.default.destinationOfSymbolicLink(atPath: $0)) != nil }
    }
    if targets.isEmpty {
      return
    }
    let label = targets.count == 1 ? tr("command.quoted_name", ["name": PathContext.posix.basename(targets[0])]) : tr("command.items", ["count": targets.count])
    let confirmed =
      remote == nil
      ? await c.app.confirm(tr("delete.trash_title"), tr("delete.trash_confirm", ["label": label]), yes: tr("delete.trash_yes"))
      : await c.app.confirm(tr("delete.ssh_title"), tr("delete.ssh_confirm", ["label": label, "host": remote!.host]), yes: tr("delete.ssh_yes"))
    if !confirmed {
      return
    }
    do {
      try await c.app.withProgress(tr(remote == nil ? "delete.trash_progress" : "delete.ssh_progress")) {
        if let remote {
          try await remote.remove(targets)
        } else {
          for path in targets {
            try Task.checkCancellation()
            try await moveToTrash(path)
          }
        }
      }
    } catch {
      await c.app.showError(error)
    }
    c.pane.marks.clear()
    // 左の窓（同じフォルダーを開いている）にも反映する。Git のタブは操作のあとに読み直される。
    await c.workspace.reloadAll()
  }
}
