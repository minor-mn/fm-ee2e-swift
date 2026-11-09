import AppKit

/// Google Drive の状態。フォルダーと鍵がそろって [ready] になるまで、タブの中に案内を出す。
enum DriveState { case checking, notInstalled, noKey, badKey, unavailable, ready }

/// Google Drive のタブ。Google ドライブ for デスクトップが作るフォルダー（マイドライブ）の直下の、このアプリ専用の
/// フォルダー（[rootFolderName]）をルートにして、その中の名前とファイルの中身を暗号化・復号する。
/// フォルダーや鍵がないときは、このタブが使えないだけ。
final class DrivePane: PathPane {
  /// 鍵ファイルの場所。
  let keyFile = keyFileLocation()

  var state = DriveState.checking

  /// 鍵を読めなかった理由・使えない理由。
  private var problem: String?

  /// マイドライブの直下の、このアプリ専用のフォルダーの名前（平文のまま）。
  static let rootFolderName = "fm-ee2e"

  /// このアプリ専用のフォルダー。使えるようになるまでは nil。
  var root: String?

  /// 開いているフォルダー。
  private var dir = ""

  /// 鍵がそろったときの、名前とファイルの暗号。
  var names: DriveNames?
  var format: EncryptedFormat?
  var key: Data?

  override var commands: [Operation: Command] {
    state != .ready
      ? [.enter: DriveSetup(), .reload: ReloadCommand(), .shell: LocalShell()]
      : [
        .enter: EnterCommand(),
        .reload: ReloadCommand(),
        .toggleHidden: ToggleHiddenCommand(),
        .shell: LocalShell(),
        .rename: DriveRename(),
        .edit: DriveEdit(),
        .delete: DriveDelete(),
        .mkdir: DriveMkdir(),
        .touch: DriveTouch(),
        .paste: DrivePaste(),
        // Google Drive のタブで G・F12 は、左のローカルへの復号してのダウンロード。
        .transfer: DriveDownload(),
      ]
  }

  override var canClip: Bool { state == .ready }

  /// C・M で選んだ項目は、Google Drive の中にだけ貼り付ける。
  override func makeClip(_ targets: [Mark], move: Bool) -> Clip? {
    DriveClip(targets.map { (path: pathOfMark($0), name: $0.entry.name, isDir: $0.entry.isDir) }, move: move)
  }

  /// 右に Google Drive を出しているとき、左のタブで G・F12 を押すと、左のローカルから暗号化してアップロードする。
  override var transferCommand: Command? { DriveUpload() }

  override var placeholder: [String]? {
    let problemLines = problem.map { [$0] } ?? []
    switch state {
    case .checking:
      return [tr("drive_pane.placeholder.checking")]
    case .notInstalled:
      return [tr("drive_pane.placeholder.not_installed"), "https://ipv4.google.com/intl/ja/drive/download/"]
    case .noKey:
      return [tr("drive_pane.placeholder.no_key", ["key_file": keyFile]), "", tr("drive_pane.placeholder.no_key_hint")]
    case .badKey:
      return [tr("drive_pane.placeholder.bad_key"), keyFile, ""] + problemLines + ["", tr("drive_pane.placeholder.retry_hint")]
    case .unavailable:
      return [tr("drive_pane.placeholder.unavailable"), ""] + problemLines + ["", tr("drive_pane.placeholder.retry_hint")]
    case .ready:
      return nil
    }
  }

  /// Google ドライブ for デスクトップのマイドライブ（~/Library/CloudStorage/GoogleDrive-アカウント/マイドライブ）。
  /// アカウントが複数あれば名前順で最初のもの。
  static func findMyDrive() async -> String? {
    let storage = p.join(homeDir, "Library", "CloudStorage")
    guard let children = try? listDirectory(storage) else {
      return nil
    }
    let accounts = children.filter { lstatPath($0).type == .directory && p.basename($0).hasPrefix("GoogleDrive-") }
      .sorted { compareCodeUnits($0, $1) < 0 }
    for account in accounts {
      for name in ["マイドライブ", "My Drive"] {
        let dir = p.join(account, name)
        if statPath(dir).type == .directory {
          return dir
        }
      }
    }
    return nil
  }

  /// フォルダー・鍵ファイルを確かめ、そろっていれば一覧を読む（起動時と L）。
  func check() async {
    state = .checking
    problem = nil
    app.requestRender()
    if !launched {
      launched = true
      launchedDriveApp = await Self.launchDriveApp()
    }
    guard let myDrive = await Self.findMyDrive() else {
      setState(.notInstalled)
      return
    }
    let loaded: Data?
    do {
      loaded = try await KeyFile.load(keyFile)
    } catch {
      // 既存の鍵ファイルは上書きしない。利用者が直すまで先に進まない。
      setState(.badKey, problem: errorMessage(error))
      return
    }
    guard let loaded else {
      setState(.noKey)
      return
    }
    format = EncryptedFormat(CryptoKitAead.load())
    let found = p.join(myDrive, Self.rootFolderName)
    do {
      if statPath(found).type != .directory {
        try FileManager.default.createDirectory(atPath: found, withIntermediateDirectories: false)
      }
    } catch {
      setState(.unavailable, problem: errorMessage(error))
      return
    }
    key = loaded
    names = DriveNames(NameCipher(loaded))
    root = found
    dir = found
    crumbs = [Self.rootFolderName]
    state = .ready
    resetCursor()
    await load()
    // 前に落ちたときなどに残った編集があれば、起動してから一度だけ聞く。
    if !recovered {
      recovered = true
      Task { await recoverEdits(self) }
    }
  }

  /// 残った編集を聞いた。
  private var recovered = false

  /// Google ドライブ for デスクトップを起動しようとした（アプリの起動中に一度だけ）。
  private var launched = false

  /// 起動時に、止まっていた Google ドライブ for デスクトップを起動した。アプリを終了するときに止める（[stopDriveApp]）。
  var launchedDriveApp = false

  /// Google ドライブ for デスクトップが入っていて、動いていなければ、前面に出さず隠したまま起動する。起動したら true。
  /// 同期はそのアプリがするので、止まっていると置いたファイルが Google Drive に上がらない。入っていなければ何もしない。
  private static func launchDriveApp() async -> Bool {
    guard let running = try? await runProcess("/usr/bin/pgrep", ["-x", "Google Drive"]) else {
      return false
    }
    if running.exitCode == 0 {
      return false
    }
    return (try? await runProcess("/usr/bin/open", ["-g", "-j", "-a", "Google Drive"]))?.exitCode == 0
  }

  /// 起動時に起動した Google ドライブ for デスクトップを、アップロードしたファイルが Google Drive に上がり終えてから止める
  /// （アプリを終了するとき）。待っている間に Esc を押したら、止めずに残す（同期は続く）。
  func stopDriveApp() async {
    if !launchedDriveApp {
      return
    }
    var cancelled = false
    if !toEvict.isEmpty {
      let message = tr("drive_pane.uploading")
      await app.withUpdatingProgress(message, onEscape: { cancelled = true }) { update in
        while !cancelled {
          // 上がり終えたものは手元から外せるので、外せなくなるまで（残りがなくなるまで）待つ。
          await evictPending()
          if toEvict.isEmpty {
            break
          }
          update(tr("drive_pane.uploading_remaining", ["count": toEvict.count]))
          await delay(milliseconds: 2000)
        }
      }
    }
    if !cancelled {
      _ = try? await runProcess("/usr/bin/osascript", ["-e", "quit app \"Google Drive\""])
    }
  }

  private func setState(_ next: DriveState, problem: String? = nil) {
    state = next
    self.problem = problem
    entries = []
    marks.clear()
    usage = nil
    app.requestRender()
  }

  override func reload() async {
    if state == .ready {
      await load()
    } else {
      await check()
    }
  }

  override var title: String { "Google Drive" }

  /// [root] から開いているフォルダーまでの名前（復号したもの）。
  private var crumbs: [String] = []

  override var location: String { state == .ready ? crumbs.joined(separator: " / ") : "" }

  /// [path] の、[root] からの名前の並び（復号したもの）。
  private func crumbsOf(_ path: String) async -> [String] {
    let root = root!
    var result = [Self.rootFolderName]
    if path != root {
      var parent = root
      for segment in p.split(p.relative(path, from: root)) {
        result.append(names!.shown(parent, segment, isFolder: true))
        parent = p.join(parent, segment)
      }
    }
    return result
  }

  /// フォルダー [dir] の中の、名前ファイルを除いた項目と、その一覧に出す名前（復号したもの）。
  /// [showHidden] でなければ、「.」で始まる名前（Drive 上の名前で）も除く。
  private func listItems(_ dir: String, showHidden: Bool) throws -> [(name: String, path: String, stat: FileStat, source: LocalSource)] {
    let paths = try listDirectory(dir)
    let siblings = Set(paths.map { p.basename($0) })
    var items: [(name: String, path: String, stat: FileStat, source: LocalSource)] = []
    for path in paths {
      let raw = p.basename(path)
      if DriveNames.isNameFile(raw) || (!showHidden && raw.hasPrefix(".")) {
        continue
      }
      let stat = statPath(path)
      guard let source = localSourceOf(path, stat) else {
        continue
      }
      items.append((names!.shown(dir, raw, isFolder: source is LocalDir, siblings: siblings), path, stat, source))
    }
    return items
  }

  override var accent: Rgb { colors.accent ?? colors.green }

  override var selection: Rgb { colors.selection ?? colors.greenDark }

  override var themeKey: ThemeKey { .drive }

  override var fileColor: Rgb { Palette.green }

  override var context: PathContext { p }

  override var dirPath: String { dir }

  /// 一覧の名前は復号したものなので、実際のパスは項目から取る。
  override func pathOf(_ entry: Entry) -> String {
    switch entry.data {
    case let file as LocalFile: file.file
    case let folder as LocalDir: folder.directory
    default: super.pathOf(entry)
    }
  }

  override func pathOfMark(_ mark: Mark) -> String { pathOf(mark.entry) }

  override func fetch() async throws -> [Entry] {
    if state != .ready {
      return []
    }
    Task { await evictPending() }
    let entries = try listItems(dir, showHidden: showHidden).map { item in
      Entry(
        name: item.name,
        isDir: item.source is LocalDir,
        size: (item.source as? LocalFile)?.size,
        modified: item.stat.modified,
        data: item.source
      )
    }
    return entries.sorted { compareEntries($0, $1) < 0 }
  }

  /// 容量は、開いているフォルダーの中身の大きさ（Used）だけを出す。df ではこの Mac の容量になり、Google Drive の容量は分からない。
  /// 設定ファイルの show_used が false なら、何も出さない（数えもしない）。
  override var usageLabels: [String] { showsUsed ? ["Used"] : [] }

  private var showsUsed: Bool { Appearance.current.theme(themeKey).showUsed }

  override func fetchUsage() async throws -> DiskUsage? {
    state == .ready && showsUsed ? DiskUsage(used: await apparentSize(dir)) : nil
  }

  override var canGoUp: Bool { state == .ready && dir != root }

  override var folderKey: String { dir }

  override func keyOf(_ entry: Entry) -> String { entry.isParent ? ".." : pathOf(entry) }

  /// [path] へ移る。[root] の外へは出ない。
  override func goToDir(_ path: String, focus: String? = nil) async {
    guard let root, path == root || p.isWithin(root, path) else {
      return
    }
    crumbs = await crumbsOf(path)
    dir = path
    resetCursor()
    await load(focus: focus)
  }

  /// [dir] の中の項目（隠しファイルを除く）を、一覧に出す名前（復号したもの）で引けるようにしたもの。
  func itemsIn(_ dir: String) async throws -> [String: LocalSource] {
    var items: [String: LocalSource] = [:]
    for item in try listItems(dir, showHidden: false) {
      items[item.name] = item.source
    }
    return items
  }

  /// [dir] の中に [name] を置く（名前を暗号化する）。[put] で、渡したパスに本体を置く。置いたパスを返す。
  /// 暗号化した名前が長すぎるときは、名前ファイルも置く（[DriveNames]）。
  @discardableResult
  func place(_ dir: String, _ name: String, isFolder: Bool, _ put: (String) async throws -> Void) async throws -> String {
    try await names!.place(dir, name, isFolder: isFolder, put)
  }

  /// Drive の [path] をゴミ箱に移す。名前ファイルがあれば一緒に移す。
  func trash(_ path: String) async throws {
    let nameFile = DriveNames.existingNameFile(of: path)
    try await moveToTrash(path)
    if let nameFile {
      try await moveToTrash(nameFile)
    }
  }

  /// [path] にあった本体を別の名前・場所に置き直したあと、元の名前ファイルを消す（新しい名前は置き直したほうにある）。
  func removeNameFile(of path: String) {
    if let nameFile = DriveNames.existingNameFile(of: path) {
      try? FileManager.default.removeItem(atPath: nameFile)
    }
  }

  /// アップロードしたが、まだ手元のデータを外せていないファイル。Drive に上がり終える前は外せないので、
  /// 残っている間は [evictInterval] ごとと、一覧を読むたびに試す。
  private var toEvict: Set<String> = []

  private static let evictInterval = 10_000

  /// 外しているところ。
  private var evicting = false

  /// 次に試すタイマー。
  private var evictTimer: OneShotTimer?

  /// [evictTimer] が待っている。
  private var evictScheduled = false

  /// アップロードした [paths] の手元のデータを外す（リモートには残る）。上がり終えるまでは外せないので、すぐには試さず
  /// [evictInterval] 後にまとめて試す（小さいファイルを続けて送るとき、1つ置くたびに残り全部を試して遅くならないように）。
  func evictLater(_ paths: [String]) {
    toEvict.formUnion(paths)
    scheduleEvict()
  }

  private func scheduleEvict() {
    if evictScheduled || toEvict.isEmpty {
      return
    }
    evictScheduled = true
    evictTimer = OneShotTimer(milliseconds: Self.evictInterval) { [weak self] in
      self?.evictScheduled = false
      Task { await self?.evictPending() }
    }
  }

  private func evictPending() async {
    if evicting || toEvict.isEmpty {
      return
    }
    evicting = true
    let paths = Array(toEvict)
    let failed = Set(await evictLocalCopies(paths))
    for path in paths {
      // 外せたもの・消えたものは、もう試さない。
      if !failed.contains(path) || !FileManager.default.fileExists(atPath: path) {
        toEvict.remove(path)
      }
    }
    evicting = false
    scheduleEvict()
  }

  /// [dir] のフォルダーの、一覧の上に出す位置（「fm-ee2e / 復号した名前 / …」）。
  func displayOf(_ dir: String) async -> String { (await crumbsOf(dir)).joined(separator: " / ") }

  /// ローカルの [from] を暗号化して [to] に置く。一時フォルダーで暗号化し終えてから移すので、途中のものは Drive に上がらない。
  func encryptFile(_ from: String, _ to: String) async throws {
    let temp = try makeTempDir("fm-ee2e-encrypt-")
    defer {
      try? FileManager.default.removeItem(atPath: temp)
    }
    let staged = p.join(temp, "payload")
    try await format!.encrypt(from: from, to: staged, key: key!)
    // mv を起動するより速い（小さいファイルが多いと効く）。別のボリュームならコピーしてから消す。
    try FileManager.default.moveItem(atPath: staged, toPath: to)
  }

  /// Drive の [from] を復号して、ローカルの [to] に置く。同じフォルダーの隠しファイルに復号し終えてから [to] の名前にする。
  /// [to] に今あるものはゴミ箱に移す。
  func decryptFile(_ from: String, _ to: String) async throws {
    let staged = p.join(p.dirname(to), ".\(p.basename(to)).fm-ee2e-partial")
    do {
      try await format!.decrypt(from: from, to: staged, key: key!)
      if lstatPath(to).type != .notFound {
        try await moveToTrash(to)
      }
      if rename(staged, to) != 0 {
        throw AppError(tr("drive_pane.cannot_move", ["path": to, "reason": String(cString: strerror(errno))]))
      }
    } catch {
      if lstatPath(staged).type != .notFound {
        try? FileManager.default.removeItem(atPath: staged)
      }
      throw error
    }
  }

  /// フォルダーなら開く。ファイルはローカルと同じく、テキスト（または種類が分からないもの）で開くアプリを決めていないものは
  /// エディタで、ほかは既定のアプリで開く（[shouldEditInTerminal]）。暗号化したものは、エディタなら E と同じく
  /// 編集して保存し直し（[editOnDrive]）、既定のアプリなら一時フォルダーに復号して開く。
  override func open(_ entry: Entry) async {
    let path = pathOf(entry)
    do {
      if entry.isDir {
        await goToDir(path)
      } else if Self.isEncrypted(path) {
        if await Self.editsInTerminal(entry.name) {
          try await editOnDrive(self, path, entry.name)
        } else {
          try await openDecrypted(path, entry.name)
        }
      } else if await shouldEditInTerminal(path) {
        await editInTerminal(app, path, workingDirectory: dir)
        await load()
      } else {
        try await openFile(path)
      }
    } catch {
      await app.showError(error)
    }
  }

  /// 復号した名前が [name] のファイルを、エディタで開くか。判定は名前（拡張子）で決まるので、同じ名前の空のファイルで確かめる。
  private static func editsInTerminal(_ name: String) async -> Bool {
    guard let dir = try? makeTempDir("fm-ee2e-type-") else {
      return false
    }
    defer {
      try? FileManager.default.removeItem(atPath: dir)
    }
    let probe = p.join(dir, name)
    FileManager.default.createFile(atPath: probe, contents: nil)
    return await shouldEditInTerminal(probe)
  }

  /// 動画をプレビューする大きさの上限（バイト）。手元から外したファイルは、まるごとダウンロードして復号するため。
  static let videoPreviewLimit = 10 * 1024 * 1024

  /// [entry] が [videoPreviewLimit] を超える動画で、プレビューしないか。
  func tooLargeToPreview(_ entry: Entry, _ kind: PreviewKind) -> Bool {
    kind == .video && (entry.size ?? Int.max) > Self.videoPreviewLimit
  }

  override func thumbnailNote(_ entry: Entry, _ kind: PreviewKind) -> String? {
    tooLargeToPreview(entry, kind) ? tr("tiles.too_large") : nil
  }

  override func thumbnail(_ entry: Entry, _ kind: PreviewKind) async -> NSImage? {
    (try? await preview(entry) { path in await makeThumbnail(path) }) ?? nil
  }

  /// [entry] のファイルから [make] でプレビューを作る。暗号化したものは一時フォルダーに復号して作り、作り終えたら消す。
  func preview<T>(_ entry: Entry, _ make: (_ path: String) async throws -> T?) async throws -> T? {
    let path = pathOf(entry)
    if !Self.isEncrypted(path) {
      return try await make(path)
    }
    let dir = try makeTempDir("fm-ee2e-preview-")
    defer {
      try? FileManager.default.removeItem(atPath: dir)
    }
    let plain = p.join(dir, "preview\(p.extension(entry.name))")
    try await format!.decrypt(from: path, to: plain, key: key!)
    return try await make(plain)
  }

  /// 先頭が暗号化ファイルのマジックか。
  private static func isEncrypted(_ path: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else {
      return false
    }
    defer {
      try? handle.close()
    }
    let head = (try? handle.read(upToCount: EncryptedFormat.magic.count)) ?? Data()
    return EncryptedFormat.hasMagic(head)
  }

  private func openDecrypted(_ path: String, _ name: String) async throws {
    // 同名のファイルを開いても衝突しないよう、開くたびに別のフォルダーを作る。
    let dir = try await createOpenTemp()
    let target = p.join(dir, name)
    do {
      try await app.withProgress(tr("drive_pane.decrypting", ["name": name])) {
        try await format!.decrypt(from: path, to: target, key: key!)
      }
    } catch {
      try? FileManager.default.removeItem(atPath: dir)
      throw error
    }
    try await openFile(target)
  }

  override func up() async {
    if canGoUp {
      await goToDir(p.dirname(dir), focus: crumbs.last)
    }
  }
}

/// 一時フォルダーを作る（Directory.systemTemp.createTemp と同じ）。
func makeTempDir(_ prefix: String, in parent: String = NSTemporaryDirectory()) throws -> String {
  var template = Array(p.join(parent, "\(prefix)XXXXXX").utf8CString)
  guard mkdtemp(&template) != nil else {
    throw AppError(tr("drive_pane.cannot_make_temp", ["reason": String(cString: strerror(errno))]))
  }
  return String(cString: template)
}
