import Foundation

/// SSH の接続先のファイル。右のタブにも左のタブにも出し、左右で別々に接続する。つなぐ前は ~/.ssh/config の Host を並べる。
final class SshPane: PathPane {
  /// つないでいる接続先。つなぐ前は nil。
  var ssh: Ssh?

  /// この接続先からつなぐ（その接続先の ~/.ssh/config の Host を並べる）。この Mac からつなぐなら nil。
  private var via: Ssh?

  /// つなぐ元の接続を待っている（左が SSH で、まだつないでいない）。
  private var waiting = false

  /// 接続を切る前に呼ぶ。この接続を経由するほかの接続を先に切るため（経由する接続が切れると、その先は閉じられない）。
  var beforeDisconnect: ((Ssh) async -> Void)?

  /// つないで、ファイルの一覧を出している。
  private var browsing: Bool { ssh != nil }

  /// S で打ったコマンド（接続先ごと、古い順）。↑↓ でたどる。アプリを閉じれば消え、どこにも書き込まない。
  var commandHistory: [String: [String]] = [:]

  /// つなぐ前（接続先の一覧）は、Enter・L・O だけ。
  override var commands: [Operation: Command] {
    browsing
      ? [
        .enter: EnterCommand(),
        .reload: ReloadCommand(),
        .delete: SshDelete(),
        .chmod: SshChmod(),
        .touch: SshTouch(),
        .mkdir: SshMkdir(),
        .rename: SshRename(),
        .edit: PathEdit(),
        .paste: SshPaste(),
        .compress: SshCompress(),
        .extract: SshExtract(),
        .goHome: SshGoHome(),
        .toggleHidden: ToggleHiddenCommand(),
        .goToPath: SshGoToPath(),
        .signOut: SshDisconnect(),
        .shell: SshShell(),
        // 右の SSH のタブで G・F12 は、左へのコピー。左のローカルへのダウンロードか、左の SSH の接続先へ（そこからつないだとき）。
        .transfer: via == nil ? SshScp() : RightSshScp(),
      ]
      : [.enter: EnterCommand(), .reload: ReloadCommand(), .signOut: SshDisconnect()]
  }

  /// 右に SSH を出しているとき、左のタブで G・F12 を押すと、左のローカルからアップロードするか、
  /// 左の SSH の接続先から送る（そこからつないだとき）。
  override var transferCommand: Command? { via == nil ? LocalScp() : LeftSshScp() }

  private static let keysBeforeConnect: Set<String> = [
    "up", "down", "pageUp", "pageDown", "home", "end", "tab", "backTab", "left", "right", "char:h", "char:?", "char:q",
  ]

  /// つなぐ前は、カーソル移動・ヘルプ・終了だけ。
  override func allowsKey(_ id: String) -> Bool { browsing || Self.keysBeforeConnect.contains(id) }

  override var canClip: Bool { ssh != nil && !readOnly }

  override func makeClip(_ targets: [Mark], move: Bool) -> Clip? {
    guard let current = ssh else { return nil }
    return SshClip(current, targets.map(pathOfMark), move: move)
  }

  override var context: PathContext { .posix }

  override var dirPath: String { dir }

  override func goToDir(_ path: String, focus: String? = nil) async {
    do {
      try await goTo(path, focus: focus)
    } catch {
      await app.showError(error)
    }
  }

  /// 開いているフォルダー（リモートの絶対パス）。
  var dir = "/"

  /// 中を見ている圧縮ファイル（[dir] にある。読むだけ）。見ていなければ nil。
  private var archive: RemoteArchive?

  /// [archive] の中で開いているフォルダー（「/」区切り、最上位は空）。
  private var archiveDir = ""

  var inArchive: Bool { archive != nil }

  private func closeArchive() {
    archive = nil
    archiveDir = ""
  }

  /// 開いているフォルダーの項目の名前（隠しファイルを含む）。同名の確認に使う。
  var names: Set<String> = []

  /// ControlMaster のソケットを置くフォルダー（0700）。ソケットのパスの長さには上限があるので /tmp に作る。
  private var socketDir: String?
  private var message: [String]?

  override var title: String {
    switch (ssh, via) {
    case (nil, nil): "SSH"
    case (nil, let via?): "SSH \(via.host) →"
    case (let current?, nil): "SSH \(current.host)"
    case (let current?, let via?): "SSH \(via.host) → \(current.host)"
    }
  }

  override var location: String {
    if let current = ssh {
      if let archive {
        return "\(current.host):\(PathContext.posix.join(archive.path, archiveDir))"
      }
      return "\(current.host):\(dir)"
    }
    if configMissing || waiting {
      return ""
    }
    if let via {
      return "\(via.host):~/.ssh/config"
    }
    return "~/.ssh/config"
  }

  /// ~/.ssh/config がない（SSH を使えない）。
  private var configMissing: Bool { ssh == nil && !(message?.isEmpty ?? true) }

  override var accent: Rgb { colors.accent ?? colors.cyan }

  override var selection: Rgb { colors.selection ?? colors.cyanDark }

  override var themeKey: ThemeKey { .ssh }

  override var placeholder: [String]? { message }

  override func fetch() async throws -> [Entry] {
    let current = ssh
    if current == nil && waiting {
      message = [tr("ssh_pane.placeholder.choose_host")]
      return []
    }
    if current == nil, let via {
      let hosts = try await readRemoteSshHosts(via)
      message = hosts == nil ? [tr("ssh_pane.placeholder.no_remote_config", ["host": via.host])] : (hosts!.isEmpty ? [] : nil)
      return (hosts ?? []).map { Entry(name: $0, isDir: false, data: SshHost($0)) }
    }
    guard let current else {
      let config = p.join(homeDir, ".ssh", "config")
      let hosts = try await readSshHosts(config)
      // ~/.ssh/config がなければ使えないことを出し、あっても Host がなければ何も出さない。
      message = !FileManager.default.fileExists(atPath: config) ? [tr("ssh_pane.placeholder.no_config")] : (hosts.isEmpty ? [] : nil)
      return hosts.map { Entry(name: $0, isDir: false, data: SshHost($0)) }
    }
    if !((try? await current.alive()) ?? false) {
      forgetConnection()
      Task { await app.showError(tr("ssh_pane.disconnected", ["host": current.host])) }
      return try await fetch()
    }
    message = nil
    if let archive {
      return archiveChildren(archive.items, archiveDir).map { item in
        Entry(name: item.name, isDir: item.isDir, size: item.isDir ? nil : item.size, modified: item.modified, data: item)
      }.sorted { compareEntries($0, $1) < 0 }
    }
    let list = try await current.list(dir)
    names = Set(list.map(\.name))
    return list.filter { showHidden || !$0.name.hasPrefix(".") }.map { e in
      Entry(
        name: e.name,
        isDir: e.isDir,
        size: e.size,
        modified: e.modified,
        executable: !e.isDir && (e.mode ?? 0) & 0x49 != 0,
        mode: e.mode,
        isLink: e.isLink,
        data: e
      )
    }.sorted { a, b in
      if a.isDir != b.isDir { return a.isDir }
      return compareCodeUnits(a.name, b.name) < 0
    }
  }

  override var canGoUp: Bool { ssh != nil && (inArchive || dir != "/") }

  override var folderKey: String {
    if ssh == nil {
      return ""
    }
    if let archive {
      return "\(PathContext.posix.join(archive.path, archiveDir))/"
    }
    return dir
  }

  override var canMark: Bool { !inArchive }

  override var readOnly: Bool { inArchive }

  override func checkWritable() async -> Bool {
    if inArchive {
      app.showStatus(tr("ssh_pane.read_only_archive"))
      return false
    }
    return true
  }

  /// 圧縮ファイルの中なら、一覧を読み直す。
  override func reload() async {
    if let archive {
      do {
        self.archive = try await RemoteArchive.open(archive.ssh, archive.path)
      } catch {
        await app.showError(error)
      }
    }
    await load()
  }

  override func markable(_ entry: Entry) -> Bool { entry.data is RemoteEntry }

  override func fetchUsage() async throws -> DiskUsage? { try await ssh?.usage(dir) }

  override func ownershipOf(_ entry: Entry) -> Ownership? {
    guard let e = entry.data as? RemoteEntry, let owner = e.owner, let group = e.group, let permissions = e.permissions else {
      return nil
    }
    return Ownership(owner, group, permissions)
  }

  func goTo(_ target: String, focus: String? = nil) async throws {
    guard let current = ssh else { return }
    dir = try await current.directory(PathContext.posix.normalize(target))
    closeArchive()
    resetCursor()
    await load(focus: focus)
  }

  override func open(_ entry: Entry) async {
    do {
      switch entry.data {
      case let host as SshHost:
        try await connect(host.host)
      case let item as ArchiveItem where item.isDir:
        archiveDir = item.path
        resetCursor()
        await load()
      case let item as ArchiveItem:
        try await viewArchiveFile(item)
      case let remote as RemoteEntry where remote.isDir:
        try await goTo(pathOf(entry))
      case is RemoteEntry where isBrowsableArchive(entry.name):
        try await openArchive(entry)
      case is RemoteEntry where previewKindOf(entry.name) != nil:
        try await openDownloaded(entry)
      case is RemoteEntry:
        // 画像・動画のほかは、接続先のエディタで開く。
        await editFile(pathOf(entry))
      default:
        break
      }
    } catch {
      await app.showError(error)
    }
  }

  /// 画像・動画を、手元の一時フォルダー（終了時に消す）にダウンロードして、既定のアプリで開く。Esc で途中でやめられる。
  private func openDownloaded(_ entry: Entry) async throws {
    let current = ssh!
    let temp = try await createOpenTemp()
    let local = p.join(temp, entry.name)
    var stop: (() -> Void)?
    do {
      try await app.withUpdatingProgress(tr("ssh_pane.downloading", ["name": entry.name]), onEscape: { stop?() }) { _ in
        try await current.download(pathOf(entry), to: local) { stop = $0 }
      }
    } catch {
      try? FileManager.default.removeItem(atPath: temp)
      if error is CancellationError {
        app.showStatus(tr("ssh_pane.download_cancelled", ["name": entry.name]))
        return
      }
      throw error
    }
    try await openFile(local)
  }

  /// 圧縮ファイルの中に入る（読むだけ）。一覧は接続先の tar・bsdtar・unzip で読む。
  private func openArchive(_ entry: Entry) async throws {
    let current = ssh!
    let path = pathOf(entry)
    let archive = try await app.withProgress(tr("ssh_pane.opening_archive", ["name": entry.name])) { try await RemoteArchive.open(current, path) }
    self.archive = archive
    archiveDir = ""
    resetCursor()
    await load()
  }

  /// 圧縮ファイルの中のファイルを、接続先の一時フォルダーに取り出して接続先のエディタで開く。閉じたら一時フォルダーを消す
  /// （読むだけなので、書き換えても圧縮ファイルには戻さない）。
  private func viewArchiveFile(_ item: ArchiveItem) async throws {
    let archive = archive!
    let current = archive.ssh
    let temp = String(decoding: try await current.run("mktemp -d /tmp/fm-ee2e-view.XXXXXX"), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    defer {
      Task {
        // 接続が切れていれば消せない。
        try? await current.remove([temp])
      }
    }
    let path = try await app.withProgress(tr("ssh_pane.extracting", ["name": item.name])) { try await archive.extract(item, temp) }
    await runInTerminal(
      app,
      "\(current.host):\(PathContext.posix.join(archive.path, item.path))",
      Ssh.executable,
      try current.interactiveArgs(temp, file: path),
      waitAfterExit: { _ in false }
    )
  }

  override func up() async {
    if let archive {
      if !archiveDir.isEmpty {
        // 出てきたフォルダーにカーソルを合わせる。
        let previous = archiveDir
        let parent = PathContext.posix.dirname(previous)
        archiveDir = parent == "." ? "" : parent
        resetCursor()
        await load(focus: PathContext.posix.basename(previous))
      } else {
        // 最上位なら圧縮ファイルから出て、カーソルを圧縮ファイルに合わせる。
        closeArchive()
        resetCursor()
        await load(focus: PathContext.posix.basename(archive.path))
      }
      return
    }
    if canGoUp {
      await goToDir(PathContext.posix.dirname(dir), focus: PathContext.posix.basename(dir))
    }
  }

  /// [host] につなぎ、ホームを開く。鍵や ssh-agent だけでつながれば、画面はそのまま。
  /// パスワードや、初めてのホストの鍵の確認が要るときだけ、画面を ssh に渡して聞かせる。
  /// そのときは、うまくいけばすぐ戻り、失敗したときだけ Enter を待つ。
  func connect(_ host: String) async throws {
    await disconnect(reload: false)
    let via = via
    // ソケットは ssh を実行するコンピューターに置く。[via] の接続先では、つなぐたびに作って、切るときに消す。
    let controlPath: String
    if let via {
      let dir = String(decoding: try await via.run("mktemp -d /tmp/fm-ee2e-ssh.XXXXXX"), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      controlPath = PathContext.posix.join(dir, "master")
    } else {
      if socketDir == nil {
        var template = Array("/tmp/fm-ee2e-ssh.XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else {
          throw AppError(tr("ssh_pane.cannot_make_temp", ["reason": String(cString: strerror(errno))]))
        }
        socketDir = String(cString: template)
      }
      controlPath = p.join(socketDir!, "master")
    }
    let next = Ssh(host, controlPath, via: via)
    let quiet = await app.withProgress(tr("ssh_pane.connecting")) { (try? await next.connectWithoutPrompt()) ?? false }
    let code = quiet ? 0 : try await connectInTerminal(next)
    if code != 0 {
      await close(next)
      await load(focus: host)
      return
    }
    ssh = next
    do {
      try await goTo(try await app.withProgress(tr("ssh_pane.connecting")) { try await next.home() })
    } catch {
      await disconnect()
      throw error
    }
  }

  /// 接続先のファイルを、接続先のエディタ（$EDITOR、なければ vim）で枠の中で開き、閉じたら一覧を読み直す。
  override func editFile(_ path: String) async {
    guard let current = ssh else {
      return
    }
    do {
      await runInTerminal(
        app,
        "\(current.host):\(path)",
        Ssh.executable,
        try current.interactiveArgs(dir, file: path),
        waitAfterExit: { _ in false }
      )
    } catch {
      await app.showError(error)
    }
    await load()
  }

  /// 接続先の一覧の行は、名前だけを出す。
  override func drawRow(_ screen: Screen, _ entry: Entry, _ x: Int, _ y: Int, _ width: Int, _ style: Style, marked: Bool) {
    if entry.data is SshHost {
      screen.text(x + 1, y, entry.name, style.copyWith(fg: accent), maxWidth: width - 2)
    } else {
      super.drawRow(screen, entry, x, y, width, style, marked: marked)
    }
  }

  /// 接続を閉じて、接続先の一覧に戻る。
  func disconnect(reload: Bool = true) async {
    let current = ssh
    if let current {
      await beforeDisconnect?(current)
    }
    forgetConnection()
    if let current {
      await close(current)
    }
    resetCursor()
    if reload {
      await load(focus: current?.host)
    }
  }

  /// [connection] のマスターの接続を閉じる。[Ssh.via] の接続先に作ったソケットのフォルダーも消す
  /// （つなぐ元の接続が切れていれば消せないが、マスターは1時間使わなければ閉じる）。
  /// パスワードなどを、枠の中の端末で聞いてつなぐ（GUI 版）。失敗したら出力を残して Enter を待つ。終了コードを返す。
  private func connectInTerminal(_ connection: Ssh) async throws -> Int {
    let (executable, args) = try connection.connectCommand()
    return await runInTerminal(app, "$ ssh \(connection.host)", executable, args, waitAfterExit: { $0 != 0 })
  }

  private func close(_ connection: Ssh) async {
    try? await connection.close()
    if let via = connection.via {
      // つなぐ元の接続が切れていれば消せない。
      _ = try? await via.run("rm -rf \(shQuote(PathContext.posix.dirname(connection.controlPath)))")
    }
  }

  /// つなぐ元を [via] にする（左の SSH の接続。nil ならこの Mac）。[waiting] なら、つなぐ元を待っていることを出す。
  /// 変わったら、今の接続を切って、つなぎ先の一覧を読み直す。
  func follow(_ via: Ssh?, waiting: Bool) async {
    if via === self.via && waiting == self.waiting {
      return
    }
    self.via = via
    self.waiting = waiting
    await disconnect()
  }

  /// 接続先の一覧に戻すため、接続とその接続先の状態を忘れる（接続は閉じない）。
  private func forgetConnection() {
    ssh = nil
    marks.clear()
    names.removeAll()
    closeArchive()
    usage = nil
    dir = "/"
  }

  /// 終了時に、接続とソケットのフォルダーを片付ける。
  func dispose() async {
    await disconnect(reload: false)
    if let socketDir {
      try? FileManager.default.removeItem(atPath: socketDir)
    }
  }
}

/// 接続先の一覧の1行。
struct SshHost {
  init(_ host: String) {
    self.host = host
  }

  let host: String
}
