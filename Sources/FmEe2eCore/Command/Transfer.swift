import Darwin
import Foundation

/// Google Drive との転送（G・F12）。左のローカルと右の Google Drive（アプリ専用のフォルダー）の間で、
/// 名前とファイルの中身を暗号化・復号しながらコピーする。フォルダーは中身ごとたどり、送り先に同じ名前のフォルダーがあれば
/// その中に入れる。同名のファイルは始める前にまとめて確かめ、上書きでは今あるものをゴミ箱に移す。
/// 送るのは裏で（転送タブ）。フォルダーの中のファイルも1つずつ項目にする。
/// 流れはここに書き、向きによる違いは継承クラスに書く。
class DriveTransferCommand: Command {
  override var label: String { "Drive G" }

  override var writes: Bool { true }

  /// 確かめる小窓の見出しと、実行するボタンの文言。
  var title: String { fatalError("title") }

  /// 確かめる小窓の本文。[label] は転送する項目（「「名前」」か「N項目」）。
  func message(_ c: CommandContext, _ label: String) -> String { fatalError("message") }

  /// 送り先の窓と、転送タブの見出しに出す送り先。
  func destination(_ c: CommandContext) -> Pane { fatalError("destination") }
  func destDisplay(_ c: CommandContext) -> String { fatalError("destDisplay") }

  /// [mark] を送る項目を [items] に足す。送り先の同名は [conflicts] で確かめる。[group] は対象の番号。
  func plan(_ c: CommandContext, _ mark: Mark, _ group: Int, _ conflicts: Conflicts, _ items: inout [TransferItem]) async throws {
    fatalError("plan")
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
    var items: [TransferItem] = []
    do {
      try await app.withProgress(tr("transfers.preparing")) {
        for (index, mark) in targets.enumerated() {
          do {
            try await plan(c, mark, index, conflicts, &items)
          } catch is PlanCancelled {
            throw PlanCancelled()
          } catch {
            // 調べられなかった対象は、失敗した項目として転送タブに出す。
            items.append(TransferItem(mark.entry.name, isDir: mark.entry.isDir, group: index) { throw error })
          }
        }
      }
    } catch {
      // PlanCancelled（同名の確認で中止）。
      return
    }
    if items.isEmpty {
      return
    }
    let job = TransferJob(tr("transfers.job", ["title": title, "dest": destDisplay(c)]), items) { job in
      // 全部送れた対象のマークを外す（失敗・中止した分は残す）。
      for (index, mark) in targets.enumerated() where job.groupDone(index) {
        pane.marks.removeAll { _, m in m.parent == mark.parent && m.entry.name == mark.entry.name }
      }
      async let a: Void = local.load()
      async let b: Void = drive.load()
      _ = await (a, b)
    }
    c.workspace.startTransfer(job, to: destination(c))
  }
}

/// Drive の送り先のフォルダー。まだないものは、最初に中へ置くときに作る（名前を暗号化して）。
private final class DriveFolder {
  init(path: String) {
    self.path = path
    parent = nil
    name = ""
  }

  init(parent: DriveFolder, name: String) {
    path = nil
    self.parent = parent
    self.name = name
  }

  private var path: String?
  private let parent: DriveFolder?
  private let name: String

  func resolve(_ drive: DrivePane) async throws -> String {
    if let path {
      return path
    }
    let made = try await drive.place(try await parent!.resolve(drive), name, isFolder: true) { try createDirectory($0) }
    path = made
    return made
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

  override func destination(_ c: CommandContext) -> Pane { c.workspace.drive }

  override func destDisplay(_ c: CommandContext) -> String { "Google Drive / \(c.workspace.drive.location)" }

  override func plan(_ c: CommandContext, _ mark: Mark, _ group: Int, _ conflicts: Conflicts, _ items: inout [TransferItem]) async throws {
    let drive = c.workspace.drive
    let dest = drive.dirPath
    try await Self.plan(
      drive, c.workspace.local.pathOfMark(mark), mark.entry.isDir, DriveFolder(path: dest), try await drive.itemsIn(dest),
      await drive.displayOf(dest), mark.entry.name, group, conflicts, &items
    )
  }

  /// ローカルの [from] を、Drive のフォルダー [folder]（今ある項目は [existing]、見せる位置は [display]）の中へ送る項目。
  /// [relative] は転送タブに出す名前。
  private static func plan(
    _ drive: DrivePane,
    _ from: String,
    _ isDir: Bool,
    _ folder: DriveFolder,
    _ existing: [String: LocalSource],
    _ display: String,
    _ relative: String,
    _ group: Int,
    _ conflicts: Conflicts,
    _ items: inout [TransferItem]
  ) async throws {
    let name = p.basename(from)
    if isDir {
      let child: DriveFolder
      var childExisting: [String: LocalSource] = [:]
      if let found = existing[name] as? LocalDir {
        // 同じ名前のフォルダーがあれば、その中に入れる。
        child = DriveFolder(path: found.directory)
        childExisting = try await drive.itemsIn(found.directory)
      } else {
        child = DriveFolder(parent: folder, name: name)
        items.append(TransferItem(relative, isDir: true, group: group) { _ = try await child.resolve(drive) })
      }
      let paths = try listDirectory(from).sorted { compareCodeUnits($0, $1) < 0 }
      for path in paths {
        if let source = localSourceOf(path, statPath(path)) {
          try await plan(
            drive, path, source is LocalDir, child, childExisting, "\(display) / \(name)", "\(relative)/\(p.basename(path))",
            group, conflicts, &items
          )
        }
      }
      return
    }
    var target = name
    var replaced: String?
    if let found = existing[name] as? LocalFile {
      switch try await conflicts.ask("Google Drive / \(display) / \(name)") {
      case .skip:
        return
      case .overwrite:
        replaced = found.file
      case .rename:
        target = uniqueName(name, Set(existing.keys))
      }
    }
    let size = statPath(from).size
    // 置き終えたもの。やり直すときは、置き終えていれば残りの手順（上書きされる側の片付け）だけを行う。
    var placed: String?
    items.append(
      TransferItem(relative, size: size, group: group) {
        if placed == nil {
          let dir = try await folder.resolve(drive)
          placed = try await drive.place(dir, target, isFolder: false) { try await drive.encryptFile(from, $0) }
        }
        // 新しいものを置き終えてから、上書きされる側をゴミ箱に移す。
        if let replaced, lstatPath(replaced).type != .notFound {
          try await drive.trash(replaced)
        }
        // 手元には残さない（Drive に上がり終えたら外す）。
        drive.evictLater([placed!])
      })
  }
}

/// 右の Google Drive のタブの対象を、左のローカルの開いているフォルダーへ復号してダウンロードする。
final class DriveDownload: DriveTransferCommand {
  override var label: String { "\(super.label) ←" }

  override var title: String { tr("transfer.download") }

  override func message(_ c: CommandContext, _ label: String) -> String {
    tr("transfer.drive_download_confirm", ["label": label, "dir": c.workspace.local.dir])
  }

  override func destination(_ c: CommandContext) -> Pane { c.workspace.local }

  override func destDisplay(_ c: CommandContext) -> String { c.workspace.local.dir }

  override func plan(_ c: CommandContext, _ mark: Mark, _ group: Int, _ conflicts: Conflicts, _ items: inout [TransferItem]) async throws {
    let dest = c.workspace.local.dir
    try await Self.plan(
      c.workspace.drive, c.workspace.drive.pathOfMark(mark), mark.entry.name, mark.entry.isDir, mark.entry.size, dest,
      try await dirNames(dest), mark.entry.name, group, conflicts, &items
    )
  }

  /// Drive の [from]（一覧での名前は [name]）を、ローカルの [dest]（今ある名前は [existing]）の中へ送る項目。
  /// [relative] は転送タブに出す名前。
  private static func plan(
    _ drive: DrivePane,
    _ from: String,
    _ name: String,
    _ isDir: Bool,
    _ size: Int?,
    _ dest: String,
    _ existing: Set<String>,
    _ relative: String,
    _ group: Int,
    _ conflicts: Conflicts,
    _ items: inout [TransferItem]
  ) async throws {
    let to = p.join(dest, name)
    if isDir {
      // 同じ名前のフォルダーがあれば、その中に入れる。
      let exists = directoryExists(to)
      if !exists {
        items.append(
          TransferItem(relative, isDir: true, group: group) {
            if !directoryExists(to) {
              try createDirectory(to)
            }
          })
      }
      let childExisting = exists ? try await dirNames(to) : []
      let children = try await drive.itemsIn(from)
      for child in children.keys.sorted(by: { compareCodeUnits($0, $1) < 0 }) {
        let source = children[child]!
        let path: String
        switch source {
        case let file as LocalFile: path = file.file
        case let dir as LocalDir: path = dir.directory
        default: fatalError("LocalSource")
        }
        try await plan(
          drive, path, child, source is LocalDir, (source as? LocalFile)?.size, to, childExisting, "\(relative)/\(child)",
          group, conflicts, &items
        )
      }
      return
    }
    var target = to
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
    items.append(TransferItem(relative, size: size, group: group) { try await drive.decryptFile(from, target) })
  }
}

/// フォルダーどうしのコピー（G・F12）。左のローカルと、右のローカル・iCloud Drive の間。
/// 送り先に同名があれば始める前に確かめ、上書きでは今あるものをゴミ箱に移してから置く。送るのは裏で（転送タブ）、
/// 失敗した項目は転送タブにその理由を出す。流れはここに書き、向きと右のタブによる違いは継承クラスに書く。
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
    if jobs.isEmpty {
      return
    }
    // 送るのは裏で（転送タブ）。
    let items = jobs.enumerated().map { index, job in
      let name = job.mark.entry.name
      let source = from.pathOfMark(job.mark)
      return TransferItem(name, isDir: job.mark.entry.isDir, size: job.mark.entry.size, group: index) {
        // やり直しのときは、前にゴミ箱へ移し終えていることがある。
        if job.overwrite && lstatPath(job.to).type != .notFound {
          try await moveToTrash(job.to)
        }
        do {
          try await copyPath(source, job.to)
        } catch {
          // 途中まで書いたもの（止めたときなど）は消す。今あったものは先にゴミ箱に移しているので、これは新しく書いたもの。
          if lstatPath(job.to).type != .notFound {
            try? FileManager.default.removeItem(atPath: job.to)
          }
          throw error
        }
        // スキップ・失敗した項目のマークは残す。
        pane.marks.removeAll { _, mark in mark.parent == job.mark.parent && mark.entry.name == name }
      }
    }
    let job = TransferJob(tr("transfers.job", ["title": title, "dest": to.dir]), items) { _ in await to.load() }
    c.workspace.startTransfer(job, to: to)
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

/// scp での転送（G・F12）。左のローカルと SSH の接続先の間か、左の SSH の接続先と、そこからつないだ右の SSH の接続先の間。
/// 送るのは裏で（転送タブ）、失敗した項目は転送タブにその理由を出す（scp は最初の接続の上で動くので、何も聞いてこない）。
/// 送り先に同名があれば始める前に確かめ、送り先と同じ場所の一時フォルダーにいったん送ってから置き換える
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

  /// 送り先の窓（転送タブに切り替える側）。
  func destPane(_ c: CommandContext) -> Pane { fatalError("destPane") }

  /// 送り先と同じファイルシステムに一時フォルダーを作る。
  func createStaging(_ c: CommandContext, _ remote: Ssh) async throws -> String { fatalError("createStaging") }

  func removeStaging(_ remote: Ssh, _ path: String) async throws { fatalError("removeStaging") }

  func destExists(_ remote: Ssh, _ path: String) async throws -> Bool { fatalError("destExists") }

  /// 送り先の中で移す。
  func destMove(_ remote: Ssh, _ from: String, _ to: String) async throws { fatalError("destMove") }

  /// 転送手段だけを差し替える（SSH は scp、Container は tar のパイプ）。
  func transfer(_ remote: Ssh, _ from: String, _ to: String) async throws -> ProcResult {
    let (program, args) = try remote.scpCommand(try sourceArg(remote, from), try destArg(remote, to))
    return try await runProcess(program, args)
  }

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
    // 送るのは裏で（転送タブ）。
    let items = jobs.enumerated().map { index, job in
      let name = job.mark.entry.name
      return TransferItem(name, isDir: job.mark.entry.isDir, size: job.mark.entry.size, group: index) { [self] in
        try await send(c, remote, from: job.from, to: job.to, overwrite: job.overwrite)
        // スキップ・失敗した項目のマークは残す。
        pane.marks.removeAll { _, mark in mark.parent == job.mark.parent && mark.entry.name == name }
      }
    }
    let job = TransferJob(tr("transfers.job", ["title": title, "dest": destDisplay(remote, dir)]), items) { _ in
      async let a: Void = local.load()
      async let b: Void = ssh.load()
      _ = await (a, b)
    }
    c.workspace.startTransfer(job, to: destPane(c))
  }

  /// 転送の後片付けに失敗して、一時フォルダーを残した。
  private struct StagingKept: Error, CustomStringConvertible {
    let description: String
  }

  /// [from] を、送り先と同じ場所の一時フォルダーに送ってから [to] に置く。止められたら、一時フォルダーを消して止める。
  private func send(_ c: CommandContext, _ remote: Ssh, from: String, to: String, overwrite: Bool) async throws {
    let staging = try await createStaging(c, remote)
    var failure: (any Error)?
    var cleanStaging = true
    do {
      let payload = destContext.join(staging, "payload")
      let previous = destContext.join(staging, "previous")
      let result = try await transfer(remote, from, payload)
      try Task.checkCancellation()
      if result.exitCode != 0 {
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw SshException(message.isEmpty ? exitStatusText(result.exitCode) : message)
      }
      // 置き換えは、止められても途中でやめない（元のデータを失わないように）。
      try await uncancelled { [self] in
        let exists = try await destExists(remote, to)
        if exists && !overwrite {
          throw SshException(tr("transfer.created_during_transfer"))
        }
        if exists {
          try await destMove(remote, to, previous)
        }
        do {
          try await destMove(remote, payload, to)
        } catch {
          let moveError = error
          if exists {
            do {
              try await destMove(remote, previous, to)
            } catch {
              throw StagingKept(description: tr("transfer.replace_failed", ["previous": previous]))
            }
          }
          throw moveError
        }
      }
    } catch let error as StagingKept {
      cleanStaging = false
      failure = error
    } catch {
      failure = error
    }
    if cleanStaging {
      do {
        try await uncancelled { [self] in try await removeStaging(remote, staging) }
      } catch {
        failure = failure ?? SshException(tr("transfer.staging_remove_failed", ["staging": staging, "error": errorMessage(error)]))
      }
    }
    if let failure {
      throw failure
    }
  }
}

/// ローカルのタブの対象を、右の SSH の接続先の開いているフォルダーへアップロードする。
class LocalScp: ScpCommand {
  override var label: String { "\(super.label) →" }

  override var title: String { tr("transfer.upload") }

  override var destContext: PathContext { .posix }

  override func destDir(_ c: CommandContext) -> String { remotePane(c).dir }

  override func destPane(_ c: CommandContext) -> Pane { remotePane(c) }

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

  override func destPane(_ c: CommandContext) -> Pane { near(c) }

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

  override func destPane(_ c: CommandContext) -> Pane { near(c) }

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

// ---- ファイルシステムの小さな操作 ----

/// [path] がフォルダーか（シンボリックリンクはたどる）。
private func directoryExists(_ path: String) -> Bool {
  statPath(path).type == .directory
}

/// フォルダーを作る。すでにフォルダーがあれば何もしない。
private func createDirectory(_ path: String) throws {
  if mkdir(path, 0o777) != 0 {
    let code = errno
    if code == EEXIST && directoryExists(path) {
      return
    }
    throw FileSystemException("Creation failed: \(String(cString: strerror(code)))", path)
  }
}
