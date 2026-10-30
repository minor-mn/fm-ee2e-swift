import Foundation

/// 対象の1ファイルを、エディタで開く（E・F8）。フォルダーは開かない。開き方はタブごとの継承クラスに書く。
class EditCommand: Command {
  override var label: String { "Edit" }

  override var writes: Bool { true }

  override var single: Bool { true }

  /// [target] のファイルを開く。
  func open(_ c: CommandContext, _ target: Mark) async throws { fatalError("open") }

  override func run(_ c: CommandContext) async {
    if let target = c.targets.first, !target.entry.isDir {
      do {
        try await open(c, target)
      } catch {
        await c.app.showError(error)
      }
    }
  }
}

/// ローカルはこの端末のエディタ、SSH は接続先のエディタで開く（[PathPane.editFile]）。
final class PathEdit: EditCommand {
  override func open(_ c: CommandContext, _ target: Mark) async throws {
    let pane = c.pane as! PathPane
    await pane.editFile(pane.pathOfMark(target))
  }
}

/// Git の窓のファイルを、エディタで開く。左がローカルならこの端末のエディタ、SSH なら接続先のエディタ。
/// 消したファイルやフォルダー（untracked）は開かない。
final class GitEdit: EditCommand {
  override func open(_ c: CommandContext, _ target: Mark) async throws {
    let pane = c.pane as! GitPane
    guard let folder = pane.dir, let line = target.entry.data as? GitStatusLine, line.kind == .file else {
      return
    }
    // Git の窓のマークは、リポジトリの一番上のフォルダーを親にしている。
    if let ssh = pane.ssh {
      let path = PathContext.posix.join(target.parent, line.path)
      let isDir = try await ssh.isDirectory(path)
      let missing = isDir ? false : !(try await ssh.exists(path))
      if isDir || missing {
        await c.app.showError(isDir ? tr("edit.is_folder") : tr("edit.missing"))
        return
      }
      _ = await runInTerminal(
        c.app,
        "\(ssh.host):\(path)",
        Ssh.executable,
        try ssh.interactiveArgs(folder, file: path),
        waitAfterExit: { _ in false }
      )
      return
    }
    let path = p.join(target.parent, line.path)
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
    if !exists || isDir.boolValue {
      await c.app.showError(exists && isDir.boolValue ? tr("edit.is_folder") : tr("edit.missing"))
      return
    }
    await editInTerminal(c.app, path, workingDirectory: folder)
  }
}

/// Google Drive のファイルを、復号してこの端末のエディタで開き、閉じたら暗号化し直して保存する（[editOnDrive]）。
final class DriveEdit: EditCommand {
  override func open(_ c: CommandContext, _ target: Mark) async throws {
    let pane = c.pane as! DrivePane
    try await editOnDrive(pane, pane.pathOfMark(target), target.entry.name)
  }
}
