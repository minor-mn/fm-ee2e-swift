import Foundation

class LocalPane: PathPane {
  override var commands: [Operation: Command] {
    [
      .enter: EnterCommand(),
      .reload: ReloadCommand(),
      .delete: LocalDelete(),
      .chmod: LocalChmod(),
      .touch: LocalTouch(),
      .mkdir: LocalMkdir(),
      .rename: LocalRename(),
      .edit: PathEdit(),
      .paste: LocalPaste(),
      .compress: LocalCompress(),
      .extract: LocalExtract(),
      .goHome: LocalGoHome(),
      .toggleHidden: ToggleHiddenCommand(),
      .goToPath: LocalGoToPath(),
      .shell: LocalShell(),
      .transfer: RightTransfer(),
    ]
  }

  override func makeClip(_ targets: [Mark], move: Bool) -> Clip? {
    LocalClip(targets.map(pathOfMark), move: move)
  }

  override var canClip: Bool { !readOnly }

  override var context: PathContext { p }

  override var dirPath: String { dir }

  override func goToDir(_ path: String, focus: String? = nil) async {
    await goTo(path, focus: focus)
  }

  /// 起動したときは、起動したフォルダー（シェルのカレント）を開く。
  var dir: String = p.absolute(FileManager.default.currentDirectoryPath)

  /// 中を見ている圧縮ファイル（[dir] にある）。見ていなければ nil。
  var archive: String?

  /// [archive] の中で開いているフォルダー（「/」区切り、最上位は空）。
  var archiveDir = ""

  /// [archive] の一覧。開いたときに一度だけ読む。
  private var archiveItems: [ArchiveItem]?

  var inArchive: Bool { archive != nil }

  /// 次の読み込みで圧縮ファイルの一覧を読み直す。
  func forgetArchiveList() { archiveItems = nil }

  override var canMark: Bool { !inArchive }

  override var title: String { "Local" }

  override var location: String { inArchive ? p.join(archive!, archiveDir) : dir }

  override var accent: Rgb { colors.accent ?? colors.purple }

  override var themeKey: ThemeKey { .local }

  /// 名前（.. を含む）ごとの所有者など。
  private var ownership: [String: Ownership] = [:]

  override func fetch() async throws -> [Entry] {
    if let archive {
      ownership = [:]
      let items: [ArchiveItem]
      if let archiveItems {
        items = archiveItems
      } else {
        items = try await listArchive(archive)
        archiveItems = items
      }
      return archiveChildren(items, archiveDir).map { item in
        Entry(name: item.name, isDir: item.isDir, size: item.isDir ? nil : item.size, modified: item.modified, data: item)
      }.sorted { compareEntries($0, $1) < 0 }
    }
    let entries = try await list(dir)
    var paths: [(String, String)] = []
    if canGoUp {
      paths.append(("..", p.dirname(dir)))
    }
    for e in entries {
      paths.append((e.name, pathOf(e)))
    }
    ownership = await Self.readOwnership(paths)
    return entries
  }

  override func ownershipOf(_ entry: Entry) -> Ownership? { ownership[entry.name] }

  /// stat でまとめて読む。読めなかった項目は結果に含めない。
  private static func readOwnership(_ paths: [(name: String, path: String)]) async -> [String: Ownership] {
    var result: [String: Ownership] = [:]
    // 引数が長くなりすぎないよう分けて呼ぶ。
    var start = 0
    while start < paths.count {
      let chunk = Array(paths[start..<min(start + 200, paths.count)])
      start += 200
      guard let run = try? await runProcess("/usr/bin/stat", ["-f", "%Su\t%Sg\t%Sp", "--"] + chunk.map(\.path)) else {
        continue
      }
      // 失敗した項目は stderr に出て行が欠けるので、行数が合うときだけ使う。
      let lines = run.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
      if lines.count != chunk.count {
        continue
      }
      for (i, item) in chunk.enumerated() {
        let parts = lines[i].components(separatedBy: "\t")
        if parts.count == 3 {
          result[item.name] = Ownership(parts[0], parts[1], parts[2])
        }
      }
    }
    return result
  }

  override func fetchUsage() async throws -> DiskUsage? {
    let run = try await runProcess("/bin/df", ["-Pk", dir])
    return run.exitCode == 0 ? parseDf(run.stdout) : nil
  }

  private func list(_ target: String) async throws -> [Entry] {
    var entries: [Entry] = []
    for path in try listDirectory(target) {
      let name = p.basename(path)
      if !showHidden && name.hasPrefix(".") {
        continue
      }
      let stat = statPath(path)
      guard let source = localSourceOf(path, stat) else {
        continue
      }
      let file = source as? LocalFile
      entries.append(
        Entry(
          name: name,
          isDir: source is LocalDir,
          size: file?.size,
          modified: stat.modified,
          // 所有者・グループ・その他のいずれかに x があれば実行ファイル。
          executable: file != nil && stat.mode & 0x49 != 0,
          mode: stat.mode & 0xfff,
          isLink: lstatPath(path).type == .link,
          data: source
        )
      )
    }
    return entries.sorted { compareEntries($0, $1) < 0 }
  }

  override var canGoUp: Bool { inArchive || p.dirname(dir) != dir }

  override var folderKey: String { inArchive ? "\(p.join(archive!, archiveDir))/" : dir }

  override func keyOf(_ entry: Entry) -> String { pathOf(entry) }

  func goTo(_ target: String, focus: String? = nil) async {
    closeArchive()
    let previous = dir
    dir = target
    resetCursor()
    await load(focus: focus)
    if let failure = error {
      // 開けないフォルダーなら元に戻す。
      dir = previous
      await load()
      await app.showError(failure)
    }
  }

  private func closeArchive() {
    archive = nil
    archiveDir = ""
    archiveItems = nil
  }

  /// 圧縮ファイルの中に入る。読めなければ元のフォルダーに戻してエラーを出す。
  private func openArchive(_ entry: Entry) async {
    archive = pathOf(entry)
    archiveDir = ""
    resetCursor()
    await load()
    if let failure = error {
      closeArchive()
      await load(focus: entry.name)
      await app.showError(failure)
    }
  }

  /// [archiveDir] を移る。
  private func goToArchiveDir(_ target: String, focus: String? = nil) async {
    archiveDir = target
    resetCursor()
    await load(focus: focus)
  }

  /// 圧縮ファイルの中のファイルを一時フォルダーに取り出して開く（終了時に消す）。
  private func openArchiveFile(_ item: ArchiveItem) async throws {
    let temp = try await createOpenTemp()
    let path: String
    do {
      path = try await app.withProgress(tr("local_pane.extracting", ["name": item.name])) { try await extractArchiveItem(archive!, item, temp) }
    } catch {
      try? FileManager.default.removeItem(atPath: temp)
      throw error
    }
    if await shouldEditInTerminal(path) {
      await editInTerminal(app, path, workingDirectory: dir)
    } else {
      try await openFile(path)
    }
  }

  /// [entry] のプレビュー用の名前。変わったら作り直す。
  func previewId(_ entry: Entry) -> String {
    "\(p.join(location, entry.name))|\(entry.size.map(String.init) ?? "null")|\(entry.modified.map { "\($0.timeIntervalSince1970)" } ?? "null")"
  }

  /// [entry] のファイルから [make] でプレビューを作る。圧縮ファイルの中のものは取り出して作る。作れなければ nil。
  func preview<T>(_ entry: Entry, _ make: (_ path: String) async throws -> T?) async throws -> T? {
    let work = try FileManager.default.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()), create: true
    ).path
    defer {
      try? FileManager.default.removeItem(atPath: work)
    }
    var path = pathOf(entry)
    if let archive {
      let extracted = p.join(work, "item")
      try FileManager.default.createDirectory(atPath: extracted, withIntermediateDirectories: false)
      path = try await extractArchiveItem(archive, entry.data as! ArchiveItem, extracted)
    }
    return try await make(path)
  }

  override func open(_ entry: Entry) async {
    do {
      if inArchive {
        let item = entry.data as! ArchiveItem
        if entry.isDir {
          await goToArchiveDir(item.path)
        } else {
          try await openArchiveFile(item)
        }
      } else if entry.isDir {
        await goTo(pathOf(entry))
      } else if isBrowsableArchive(entry.name) {
        await openArchive(entry)
      } else if entry.executable {
        await exec(entry)
      } else if await shouldEditInTerminal(pathOf(entry)) {
        await editFile(pathOf(entry))
      } else {
        try await openFile(pathOf(entry))
      }
    } catch {
      await app.showError(error)
    }
  }

  /// 引数を聞いて、このフォルダーで実行する。引数はシェルで解釈する。
  private func exec(_ entry: Entry) async {
    guard let args = await app.askExecArgs(entry.name, dir) else {
      return
    }
    await runInTerminal(app, "\(entry.name) \(args)", "/bin/sh", ["-c", "\"$0\" \(args)", pathOf(entry)], workingDirectory: dir)
    // 実行したプログラムがファイルを作ったり消したりした場合に備える。
    await load()
  }

  /// 枠の中でエディタ（$EDITOR、なければ vim）を開き、閉じたら読み直す。
  override func editFile(_ path: String) async {
    await editInTerminal(app, path, workingDirectory: dir)
    await load()
  }

  override var readOnly: Bool { inArchive }

  override func checkWritable() async -> Bool {
    if inArchive {
      app.showStatus(tr("local_pane.read_only_archive"))
      return false
    }
    return true
  }

  override func reload() async {
    forgetArchiveList()
    await load()
  }

  override func up() async {
    if let archive {
      if !archiveDir.isEmpty {
        let parent = PathContext.posix.dirname(archiveDir)
        await goToArchiveDir(parent == "." ? "" : parent, focus: PathContext.posix.basename(archiveDir))
      } else {
        // 最上位なら圧縮ファイルから出て、カーソルを圧縮ファイルに合わせる。
        closeArchive()
        resetCursor()
        await load(focus: p.basename(archive))
      }
      return
    }
    let parent = p.dirname(dir)
    if parent != dir {
      await goTo(parent, focus: p.basename(dir))
    }
  }
}

/// 枠の中でエディタ（$EDITOR、なければ vim）を開き、閉じたら戻る。
func editInTerminal(_ app: App, _ path: String, workingDirectory: String) async {
  let editor = ProcessInfo.processInfo.environment["EDITOR"]
  await runInTerminal(
    app, path, "/bin/sh",
    ["-c", "\(editor == nil || editor!.isEmpty ? "vim" : editor!) \"$0\"", path],
    workingDirectory: workingDirectory,
    waitAfterExit: { _ in false }
  )
}

/// 右のタブのローカル。左のローカルと同じことができ、G・F12 で左のローカルとの間でコピーする。
final class RightLocalPane: LocalPane {
  /// 右のローカルのタブで G・F12 は、左のローカルへのコピー。
  override var commands: [Operation: Command] {
    var map = super.commands
    map[.transfer] = LocalCopyToLeft()
    return map
  }

  /// 右にローカルを出しているとき、左のタブで G・F12 を押すと、右のローカルへコピーする。
  override var transferCommand: Command? { LocalCopyToRight() }
}

/// 右の窓に出せるタブがないときの右の窓。[placeholder] の案内だけを出す。
final class NoTabPane: Pane {
  /// [placeholder] は出す文言の名前（[tr] の key）。文言のファイルを読み直したら、出す文も変わる。
  init(_ app: App, _ placeholder: [String]) {
    placeholderKeys = placeholder
    super.init(app)
  }

  private let placeholderKeys: [String]

  override var placeholder: [String]? { placeholderKeys.map { tr($0) } }

  override var title: String { "" }

  override var location: String { "" }

  override var accent: Rgb { colors.outline }

  override func fetch() async throws -> [Entry] { [] }

  override var canGoUp: Bool { false }

  override var folderKey: String { "" }
}
