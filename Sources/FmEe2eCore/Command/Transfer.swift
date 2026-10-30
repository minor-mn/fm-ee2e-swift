import Darwin
import Foundation

/// Google Drive との転送（G・F12）。左のローカルと右の Google Drive（アプリ専用のフォルダー）の間で、
/// 名前とファイルの中身を暗号化・復号しながらコピーする。フォルダーは中身ごとたどり、送り先に同じ名前のフォルダーがあれば
/// その中に入れる。同名のファイルは確かめ、上書きでは今あるものをゴミ箱に移す。失敗した項目は最後にまとめてエラーで出す。
/// 流れはここに書き、向きによる違いは継承クラスに書く。
class DriveTransferCommand: Command {
  override var label: String { "Drive G" }

  override var writes: Bool { true }

  /// 確かめる小窓の見出しと、実行するボタンの文言。
  var title: String { fatalError("title") }

  /// 確かめる小窓の本文。[label] は転送する項目（「「名前」」か「N項目」）。
  func message(_ c: CommandContext, _ label: String) -> String { fatalError("message") }

  /// [mark] を送る。送り先の同名は [conflicts] で確かめ、送るファイルごとに [update] で知らせ、失敗は [errors] に足す。
  func send(
    _ c: CommandContext,
    _ mark: Mark,
    _ conflicts: Conflicts,
    _ update: (String) -> Void,
    _ errors: inout [String]
  ) async throws {
    fatalError("send")
  }

  override func run(_ c: CommandContext) async {
    let pane = c.pane
    let app = c.app
    let drive = c.workspace.drive
    let local = c.workspace.local
    if drive.state != .ready {
      app.showStatus(tr("transfer.drive_unavailable"))
      return
    }
    if !drive.ready {
      app.showStatus(tr("transfer.drive_loading"))
      return
    }
    let targets = c.targets
    if targets.isEmpty {
      return
    }
    if !(await local.checkWritable()) {
      return
    }
    if !(await app.confirm(title, message(c, quotedLabel(targets)), yes: title)) {
      return
    }
    let conflicts = Conflicts { path in await askConflict(app, path) }
    var errors: [String] = []
    do {
      try await app.withUpdatingProgress(tr("transfer.in_progress", ["title": title])) { update in
        for mark in targets {
          let before = errors.count
          try await send(c, mark, conflicts, { name in update(tr("transfer.in_progress_item", ["title": self.title, "name": name])) }, &errors)
          // 失敗した項目のマークは残す。
          if errors.count == before {
            pane.marks.removeAll { _, m in m.parent == mark.parent && m.entry.name == mark.entry.name }
          }
        }
      }
    } catch is PlanCancelled {
      // 途中で中止。済んだ分はそのまま。
    } catch {
      await app.showError(error)
      return
    }
    if !errors.isEmpty {
      await app.showError(errors.joined(separator: "\n"))
    }
    async let a: Void = local.load()
    async let b: Void = drive.load()
    _ = await (a, b)
  }
}

/// 左のローカルのタブの対象を、右の Google Drive の開いているフォルダーへ暗号化してアップロードする。
final class DriveUpload: DriveTransferCommand {
  /// ファンクションキーの帯で、転送の向き（左→右・右→左）を見せる。
  override var label: String { "\(super.label) →" }

  override var title: String { tr("transfer.upload") }

  override func message(_ c: CommandContext, _ label: String) -> String {
    tr("transfer.drive_upload_confirm", ["label": label, "location": c.workspace.drive.location])
  }

  override func send(
    _ c: CommandContext,
    _ mark: Mark,
    _ conflicts: Conflicts,
    _ update: (String) -> Void,
    _ errors: inout [String]
  ) async throws {
    let drive = c.workspace.drive
    try await DriveUpload.upload(
      drive,
      c.workspace.local.pathOfMark(mark),
      mark.entry.isDir,
      drive.dirPath,
      conflicts,
      update,
      &errors
    )
  }

  /// ローカルの [from] を、Drive の [dest] の中へ。
  private static func upload(
    _ drive: DrivePane,
    _ from: String,
    _ isDir: Bool,
    _ dest: String,
    _ conflicts: Conflicts,
    _ update: (String) -> Void,
    _ errors: inout [String]
  ) async throws {
    let name = p.basename(from)
    do {
      let items = try await drive.itemsIn(dest)
      let existing = items[name]
      if isDir {
        let dir: String
        if let existing = existing as? LocalDir {
          dir = existing.directory
        } else {
          dir = try await drive.encryptedPath(dest, name, isFolder: true)
          try createDirectory(dir)
        }
        for path in try listDirectory(from) {
          if let source = localSourceOf(path, statPath(path)) {
            try await upload(drive, path, source is LocalDir, dir, conflicts, update, &errors)
          }
        }
        return
      }
      var target = name
      var replaced: String?
      if let existing = existing as? LocalFile {
        switch try await conflicts.ask("Google Drive / \(await drive.displayOf(dest)) / \(name)") {
        case .skip:
          return
        case .overwrite:
          replaced = existing.file
        case .rename:
          target = uniqueName(name, Set(items.keys))
        }
      }
      update(name)
      let to = try await drive.encryptedPath(dest, target, isFolder: false)
      try await drive.encryptFile(from, to)
      // 新しいものを置き終えてから、上書きされる側をゴミ箱に移す。
      if let replaced {
        try await moveToTrash(replaced)
      }
      // 手元には残さない（Drive に上がり終えたら外す）。
      drive.evictLater([to])
    } catch is PlanCancelled {
      throw PlanCancelled()
    } catch {
      errors.append("\(name): \(errorMessage(error))")
    }
  }
}

/// 右の Google Drive のタブの対象を、左のローカルの開いているフォルダーへ復号してダウンロードする。
final class DriveDownload: DriveTransferCommand {
  override var label: String { "\(super.label) ←" }

  override var title: String { tr("transfer.download") }

  override func message(_ c: CommandContext, _ label: String) -> String {
    tr("transfer.drive_download_confirm", ["label": label, "dir": c.workspace.local.dir])
  }

  override func send(
    _ c: CommandContext,
    _ mark: Mark,
    _ conflicts: Conflicts,
    _ update: (String) -> Void,
    _ errors: inout [String]
  ) async throws {
    let drive = c.workspace.drive
    try await DriveDownload.download(
      drive,
      drive.pathOfMark(mark),
      mark.entry.name,
      mark.entry.isDir,
      c.workspace.local.dir,
      conflicts,
      update,
      &errors
    )
  }

  /// Drive の [from]（一覧での名前は [name]）を、ローカルの [dest] の中へ。
  private static func download(
    _ drive: DrivePane,
    _ from: String,
    _ name: String,
    _ isDir: Bool,
    _ dest: String,
    _ conflicts: Conflicts,
    _ update: (String) -> Void,
    _ errors: inout [String]
  ) async throws {
    do {
      let to = p.join(dest, name)
      if isDir {
        // 同じ名前のフォルダーがあれば、その中に入れる。
        if !directoryExists(to) {
          try createDirectory(to)
        }
        let items = try await drive.itemsIn(from)
        for child in items.keys {
          let source = items[child]!
          let path: String
          switch source {
          case let file as LocalFile: path = file.file
          case let dir as LocalDir: path = dir.directory
          default: fatalError("LocalSource")
          }
          try await download(drive, path, child, source is LocalDir, to, conflicts, update, &errors)
        }
        return
      }
      var target = to
      let existing = try await dirNames(dest)
      if existing.contains(name) {
        switch try await conflicts.ask(to) {
        case .skip:
          return
        case .overwrite:
          break
        case .rename:
          target = p.join(dest, uniqueName(name, existing))
        }
      }
      update(name)
      try await drive.decryptFile(from, target)
    } catch is PlanCancelled {
      throw PlanCancelled()
    } catch {
      errors.append("\(name): \(errorMessage(error))")
    }
  }
}

/// フォルダーどうしのコピー（G・F12）。左のローカルと、右のローカル・iCloud Drive の間。
/// 送り先に同名があれば確かめ、上書きでは今あるものをゴミ箱に移してから置く。転送の間は何件目を送っているかを
/// 「処理中」の小窓に出し、失敗した項目は最後にまとめてエラーで出す。流れはここに書き、向きと右のタブによる違いは継承クラスに書く。
class FolderCopyCommand: Command {
  override var writes: Bool { true }

  /// 確かめる小窓の見出しと、実行するボタンの文言。
  var title: String { fatalError("title") }

  /// 確かめる小窓の本文。[label] は転送する項目（「「名前」」か「N項目」）。
  func message(_ c: CommandContext, _ label: String) -> String { fatalError("message") }

  /// 送り元の窓。
  func source(_ c: CommandContext) -> LocalPane { fatalError("source") }

  /// 送り先の窓。
  func dest(_ c: CommandContext) -> LocalPane { fatalError("dest") }

  /// 右のタブを使えるかを確かめる。だめなら理由を出して false。
  func prepare(_ c: CommandContext) async -> Bool { true }

  override func run(_ c: CommandContext) async {
    let pane = c.pane
    let app = c.app
    if !(await prepare(c)) {
      return
    }
    let from = source(c)
    let to = dest(c)
    let targets = c.targets
    if targets.isEmpty {
      return
    }
    if !(await from.checkWritable()) {
      return
    }
    if !(await to.checkWritable()) {
      return
    }
    if !(await app.confirm(title, message(c, quotedLabel(targets)), yes: title)) {
      return
    }
    var existing: Set<String>
    do {
      existing = try await dirNames(to.dir)
    } catch {
      await app.showError(error)
      return
    }
    let conflicts = Conflicts { path in await askConflict(app, path) }
    var jobs: [(mark: Mark, to: String, overwrite: Bool)] = []
    do {
      for mark in targets {
        let name = mark.entry.name
        var target = name
        var overwrite = false
        if existing.contains(name) {
          switch try await conflicts.ask(to.pathOf(mark.entry)) {
          case .skip:
            continue
          case .overwrite:
            overwrite = true
          case .rename:
            target = uniqueName(name, existing)
          }
        }
        existing.insert(target)
        jobs.append((mark: mark, to: p.join(to.dir, target), overwrite: overwrite))
      }
    } catch {
      // PlanCancelled（途中で中止）。
      return
    }
    var errors: [String] = []
    await app.withUpdatingProgress(tr("transfer.in_progress", ["title": title])) { update in
      for (index, job) in jobs.enumerated() {
        let name = job.mark.entry.name
        update(tr("transfer.in_progress_count", ["title": title, "index": index + 1, "total": jobs.count, "name": name]))
        do {
          if job.overwrite {
            try await moveToTrash(job.to)
          }
          try await copyPath(from.pathOfMark(job.mark), job.to)
          // スキップ・失敗した項目のマークは残す。
          pane.marks.removeAll { _, mark in mark.parent == job.mark.parent && mark.entry.name == name }
        } catch {
          errors.append("\(name): \(errorMessage(error))")
        }
      }
    }
    if !errors.isEmpty {
      await app.showError(errors.joined(separator: "\n"))
    }
    await to.load()
  }
}

/// iCloud Drive との転送。
class ICloudTransferCommand: FolderCopyCommand {
  override var label: String { "iCloud G" }

  override func prepare(_ c: CommandContext) async -> Bool {
    let icloud = c.workspace.icloud
    if icloud.state != .ready {
      c.app.showStatus(tr("transfer.icloud_unavailable"))
      return false
    }
    if !icloud.ready {
      c.app.showStatus(tr("transfer.icloud_loading"))
      return false
    }
    return true
  }
}

/// 左のローカルのタブの対象を、右の iCloud Drive の開いているフォルダーへアップロードする。
final class ICloudUpload: ICloudTransferCommand {
  override var label: String { "\(super.label) →" }

  override var title: String { tr("transfer.upload") }

  override func message(_ c: CommandContext, _ label: String) -> String {
    tr("transfer.icloud_upload_confirm", ["label": label, "location": c.workspace.icloud.location])
  }

  override func source(_ c: CommandContext) -> LocalPane { c.workspace.local }

  override func dest(_ c: CommandContext) -> LocalPane { c.workspace.icloud }
}

/// 右の iCloud Drive のタブの対象を、左のローカルの開いているフォルダーへダウンロードする。
final class ICloudDownload: ICloudTransferCommand {
  override var label: String { "\(super.label) ←" }

  override var title: String { tr("transfer.download") }

  override func message(_ c: CommandContext, _ label: String) -> String {
    tr("transfer.icloud_download_confirm", ["label": label, "dir": c.workspace.local.dir])
  }

  override func source(_ c: CommandContext) -> LocalPane { c.workspace.icloud }

  override func dest(_ c: CommandContext) -> LocalPane { c.workspace.local }
}

/// 右のローカルとのコピー。
class LocalCopyCommand: FolderCopyCommand {
  override var label: String { "Copy G" }

  override var title: String { tr("transfer.copy") }

  override func message(_ c: CommandContext, _ label: String) -> String {
    tr("transfer.copy_confirm", ["label": label, "dir": dest(c).dir])
  }
}

/// 左のローカルのタブの対象を、右のローカルの開いているフォルダーへコピーする。
final class LocalCopyToRight: LocalCopyCommand {
  override var label: String { "\(super.label) →" }

  override func source(_ c: CommandContext) -> LocalPane { c.workspace.local }

  override func dest(_ c: CommandContext) -> LocalPane { c.workspace.localRight }
}

/// 右のローカルのタブの対象を、左のローカルの開いているフォルダーへコピーする。
final class LocalCopyToLeft: LocalCopyCommand {
  override var label: String { "\(super.label) ←" }

  override func source(_ c: CommandContext) -> LocalPane { c.workspace.localRight }

  override func dest(_ c: CommandContext) -> LocalPane { c.workspace.local }
}

/// scp での転送（G・F12）。左のローカルと SSH の接続先の間か、左の SSH の接続先と、そこからつないだ右の SSH の接続先の間。転送の間は何件目を送っているかを「処理中」の小窓に出し、
/// 失敗した項目は最後にまとめてエラーで出す（scp は最初の接続の上で動くので、何も聞いてこない）。
/// 送り先に同名があれば確かめ、送り先と同じ場所の一時フォルダーにいったん送ってから置き換える
/// （同名のフォルダーへ直接 scp すると入れ子になるため）。流れはここに書き、向きによる違いは継承クラスに書く。
class ScpCommand: Command {
  override var label: String { "SCP G" }

  override var writes: Bool { true }

  /// 確かめる小窓の見出しと、実行するボタンの文言。
  var title: String { fatalError("title") }

  /// 送り先のパスの書き方。
  var destContext: PathContext { fatalError("destContext") }

  /// 送り先のフォルダー。
  func destDir(_ c: CommandContext) -> String { fatalError("destDir") }

  /// scp を実行する側の窓（ローカルのタブか、左の SSH）。書き込めるかを確かめ、終わったら読み直す。
  func near(_ c: CommandContext) -> Pane { c.workspace.local }

  /// 接続先の窓。ふつうは右の SSH。左が SSH で右がローカルのときは左の SSH。
  func remotePane(_ c: CommandContext) -> SshPane { c.workspace.ssh }

  /// [mark] の送り元のパス。
  func sourcePath(_ c: CommandContext, _ mark: Mark) -> String { fatalError("sourcePath") }

  /// scp に渡す送り元・送り先（接続先のものは「host:パス」の形）。
  func sourceArg(_ remote: Ssh, _ path: String) throws -> String { fatalError("sourceArg") }
  func destArg(_ remote: Ssh, _ path: String) throws -> String { fatalError("destArg") }

  /// 画面に見せる送り元・送り先。
  func sourceDisplay(_ remote: Ssh, _ path: String) -> String { fatalError("sourceDisplay") }
  func destDisplay(_ remote: Ssh, _ path: String) -> String { fatalError("destDisplay") }

  /// 送り先のフォルダーの名前（表示後に作られたもの・隠しファイルを含む）。
  func destNames(_ c: CommandContext, _ remote: Ssh) async throws -> Set<String> { fatalError("destNames") }

  /// 送り先と同じファイルシステムに一時フォルダーを作る。
  func createStaging(_ c: CommandContext, _ remote: Ssh) async throws -> String { fatalError("createStaging") }

  func removeStaging(_ remote: Ssh, _ path: String) async throws { fatalError("removeStaging") }

  func destExists(_ remote: Ssh, _ path: String) async throws -> Bool { fatalError("destExists") }

  /// 送り先の中で移す。
  func destMove(_ remote: Ssh, _ from: String, _ to: String) async throws { fatalError("destMove") }

  override func run(_ c: CommandContext) async {
    let pane = c.pane
    let app = c.app
    let local = near(c)
    let ssh = remotePane(c)
    guard let remote = ssh.ssh else {
      app.showStatus(tr("transfer.ssh_not_selected"))
      return
    }
    if !(await local.checkWritable()) {
      return
    }
    let targets = c.targets
    if !ssh.ready || targets.isEmpty {
      return
    }
    let label = targets.count == 1 ? targets[0].entry.name : tr("command.items", ["count": targets.count])
    if !(await app.confirm(title, tr("transfer.scp_confirm", ["label": label, "title": title]), yes: title)) {
      return
    }
    let dir = destDir(c)
    var existing: Set<String>
    do {
      existing = try await destNames(c, remote)
    } catch {
      await app.showError(error)
      return
    }
    let conflicts = Conflicts { path in await askConflict(app, path) }
    var jobs: [(mark: Mark, from: String, to: String, overwrite: Bool)] = []
    do {
      for mark in targets {
        let name = mark.entry.name
        var target = name
        var overwrite = false
        if existing.contains(name) {
          switch try await conflicts.ask(destDisplay(remote, destContext.join(dir, name))) {
          case .skip:
            continue
          case .overwrite:
            overwrite = true
          case .rename:
            target = uniqueName(name, existing)
          }
        }
        existing.insert(target)
        jobs.append((mark: mark, from: sourcePath(c, mark), to: destContext.join(dir, target), overwrite: overwrite))
      }
    } catch {
      // PlanCancelled（途中で中止）。
      return
    }
    if jobs.isEmpty {
      return
    }
    var errors: [String] = []
    await app.withUpdatingProgress(tr("transfer.in_progress", ["title": title])) { update in
      for (index, job) in jobs.enumerated() {
        let name = job.mark.entry.name
        update(tr("transfer.in_progress_count", ["title": title, "index": index + 1, "total": jobs.count, "name": name]))
        var staging: String?
        var cleanStaging = true
        do {
          staging = try await createStaging(c, remote)
          let payload = destContext.join(staging!, "payload")
          let previous = destContext.join(staging!, "previous")
          let (program, args) = try remote.scpCommand(try sourceArg(remote, job.from), try destArg(remote, payload))
          let result = try await runProcess(program, args)
          if result.exitCode != 0 {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            errors.append("\(name): \(message.isEmpty ? exitStatusText(result.exitCode) : message)")
          } else {
            let exists = try await destExists(remote, job.to)
            if exists && !job.overwrite {
              throw SshException(tr("transfer.created_during_transfer"))
            }
            if exists {
              try await destMove(remote, job.to, previous)
            }
            do {
              try await destMove(remote, payload, job.to)
            } catch {
              let moveError = error
              if exists {
                do {
                  try await destMove(remote, previous, job.to)
                } catch {
                  cleanStaging = false
                  throw SshException(tr("transfer.replace_failed", ["previous": previous]))
                }
              }
              throw moveError
            }
            // スキップ・失敗した項目のマークは残す。
            pane.marks.removeAll { _, mark in mark.parent == job.mark.parent && mark.entry.name == name }
          }
        } catch {
          errors.append("\(name): \(errorMessage(error))")
        }
        if let staging, cleanStaging {
          do {
            try await removeStaging(remote, staging)
          } catch {
            errors.append(tr("transfer.staging_remove_failed", ["staging": staging, "error": errorMessage(error)]))
          }
        }
      }
    }
    if !errors.isEmpty {
      await app.showError(errors.joined(separator: "\n"))
    }
    async let a: Void = local.load()
    async let b: Void = ssh.load()
    _ = await (a, b)
  }
}

/// ローカルのタブの対象を、右の SSH の接続先の開いているフォルダーへアップロードする。
class LocalScp: ScpCommand {
  override var label: String { "\(super.label) →" }

  override var title: String { tr("transfer.upload") }

  override var destContext: PathContext { .posix }

  override func destDir(_ c: CommandContext) -> String { remotePane(c).dir }

  override func sourcePath(_ c: CommandContext, _ mark: Mark) -> String { (near(c) as! PathPane).pathOfMark(mark) }

  override func sourceArg(_ remote: Ssh, _ path: String) throws -> String { path }

  override func destArg(_ remote: Ssh, _ path: String) throws -> String { try remote.remote(path) }

  override func sourceDisplay(_ remote: Ssh, _ path: String) -> String { path }

  override func destDisplay(_ remote: Ssh, _ path: String) -> String { "\(remote.host):\(path)" }

  override func destNames(_ c: CommandContext, _ remote: Ssh) async throws -> Set<String> {
    Set(try await remote.list(remotePane(c).dir).map { $0.name })
  }

  override func createStaging(_ c: CommandContext, _ remote: Ssh) async throws -> String {
    try await remote.transferTemp(remotePane(c).dir)
  }

  override func removeStaging(_ remote: Ssh, _ path: String) async throws { try await remote.remove([path]) }

  override func destExists(_ remote: Ssh, _ path: String) async throws -> Bool { try await remote.exists(path) }

  override func destMove(_ remote: Ssh, _ from: String, _ to: String) async throws { try await remote.move(from, to) }
}

/// SSH のタブの対象を、左のローカルの開いているフォルダーへダウンロードする。
class SshScp: ScpCommand {
  override var label: String { "\(super.label) ←" }

  override var title: String { tr("transfer.download") }

  override var destContext: PathContext { p }

  /// 送り先のローカルのタブ。
  private func dest(_ c: CommandContext) -> LocalPane { near(c) as! LocalPane }

  override func destDir(_ c: CommandContext) -> String { dest(c).dir }

  override func sourcePath(_ c: CommandContext, _ mark: Mark) -> String { remotePane(c).pathOfMark(mark) }

  override func sourceArg(_ remote: Ssh, _ path: String) throws -> String { try remote.remote(path) }

  override func destArg(_ remote: Ssh, _ path: String) throws -> String { path }

  override func sourceDisplay(_ remote: Ssh, _ path: String) -> String { "\(remote.host):\(path)" }

  override func destDisplay(_ remote: Ssh, _ path: String) -> String { path }

  override func destNames(_ c: CommandContext, _ remote: Ssh) async throws -> Set<String> {
    try await dirNames(dest(c).dir)
  }

  override func createStaging(_ c: CommandContext, _ remote: Ssh) async throws -> String {
    try makeTempDir(".fm-ee2e-scp.", in: dest(c).dir)
  }

  override func removeStaging(_ remote: Ssh, _ path: String) async throws {
    try FileManager.default.removeItem(atPath: path)
  }

  override func destExists(_ remote: Ssh, _ path: String) async throws -> Bool {
    lstatPath(path).type != .notFound
  }

  override func destMove(_ remote: Ssh, _ from: String, _ to: String) async throws { try await movePath(from, to) }
}

/// 左の SSH の接続先の対象を、そこからつないだ右の SSH の接続先の開いているフォルダーへ送る。scp は左の接続先で実行する。
final class LeftSshScp: LocalScp {
  override var title: String { tr("transfer.copy_right") }

  override func near(_ c: CommandContext) -> Pane { c.workspace.sshLeft }
}

/// 左が SSH で右がローカルのとき、左の SSH の接続先の対象を、右のローカルのフォルダーへダウンロードする。
final class LeftSshDownload: SshScp {
  override var label: String { "SCP G →" }

  override func near(_ c: CommandContext) -> Pane { c.workspace.localRight }

  override func remotePane(_ c: CommandContext) -> SshPane { c.workspace.sshLeft }
}

/// 左が SSH で右がローカルのとき、右のローカルの対象を、左の SSH の接続先のフォルダーへアップロードする。
final class RightLocalUpload: LocalScp {
  override var label: String { "SCP G ←" }

  override func near(_ c: CommandContext) -> Pane { c.workspace.localRight }

  override func remotePane(_ c: CommandContext) -> SshPane { c.workspace.sshLeft }
}

/// 右の SSH の接続先の対象を、つなぐ元の左の SSH の接続先の開いているフォルダーへ送る。scp は左の接続先で実行する。
/// 送り先の操作は、右の接続のつなぐ元（[Ssh.via]）で行う。
final class RightSshScp: ScpCommand {
  override var label: String { "\(super.label) ←" }

  override var title: String { tr("transfer.copy_left") }

  override func near(_ c: CommandContext) -> Pane { c.workspace.sshLeft }

  override var destContext: PathContext { .posix }

  override func destDir(_ c: CommandContext) -> String { c.workspace.sshLeft.dir }

  override func sourcePath(_ c: CommandContext, _ mark: Mark) -> String { c.workspace.ssh.pathOfMark(mark) }

  override func sourceArg(_ remote: Ssh, _ path: String) throws -> String { try remote.remote(path) }

  override func destArg(_ remote: Ssh, _ path: String) throws -> String { path }

  override func sourceDisplay(_ remote: Ssh, _ path: String) -> String { "\(remote.host):\(path)" }

  override func destDisplay(_ remote: Ssh, _ path: String) -> String { "\(remote.via!.host):\(path)" }

  override func destNames(_ c: CommandContext, _ remote: Ssh) async throws -> Set<String> {
    Set(try await remote.via!.list(c.workspace.sshLeft.dir).map { $0.name })
  }

  override func createStaging(_ c: CommandContext, _ remote: Ssh) async throws -> String {
    try await remote.via!.transferTemp(c.workspace.sshLeft.dir)
  }

  override func removeStaging(_ remote: Ssh, _ path: String) async throws { try await remote.via!.remove([path]) }

  override func destExists(_ remote: Ssh, _ path: String) async throws -> Bool { try await remote.via!.exists(path) }

  override func destMove(_ remote: Ssh, _ from: String, _ to: String) async throws {
    try await remote.via!.move(from, to)
  }
}

// ---- ファイルシステムの小さな操作（Dart の Directory の代わり） ----

/// [path] がフォルダーか（シンボリックリンクはたどる。Dart の Directory.exists と同じ）。
private func directoryExists(_ path: String) -> Bool {
  statPath(path).type == .directory
}

/// フォルダーを作る。すでにフォルダーがあれば何もしない（Dart の Directory.create と同じ）。
private func createDirectory(_ path: String) throws {
  if mkdir(path, 0o777) != 0 {
    let code = errno
    if code == EEXIST && directoryExists(path) {
      return
    }
    throw FileSystemException("Creation failed: \(String(cString: strerror(code)))", path)
  }
}
