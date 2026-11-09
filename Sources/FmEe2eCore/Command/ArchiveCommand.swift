/// 対象を、形式と名前を聞いて開いているフォルダーに圧縮する（Z）。
/// 流れはここに書き、使える形式と圧縮のしかたは、タブごとの継承クラスに書く。
class CompressCommand: Command {
  override var writes: Bool { true }

  /// 使える形式。
  func formats(_ c: CommandContext) async throws -> [ArchiveFormat] { fatalError("formats") }

  /// どの形式も使えないときに出す文。
  func unavailable(_ c: CommandContext) -> String { tr("archive_command.unavailable") }

  /// 圧縮先のフォルダー（小窓に出す）。
  func place(_ c: CommandContext) -> String { fatalError("place") }

  /// Esc で止められる。接続先で動かすものは、手元の ssh を止めても接続先のコマンドが動き続けることがあるので止めない。
  var cancellable: Bool { false }

  /// 圧縮先のフォルダーにある名前。
  func existing(_ c: CommandContext) async throws -> Set<String> { fatalError("existing") }

  /// [targets] を、圧縮先のフォルダーの [name] に [format] で圧縮する。項目を入れるたびに [progress] に知らせる（知らせられなければ呼ばない）。
  func compress(
    _ c: CommandContext, _ targets: [Mark], _ name: String, _ format: ArchiveFormat, progress: @escaping ArchiveProgress
  ) async throws {
    fatalError("compress")
  }

  override func run(_ c: CommandContext) async {
    let pane = c.pane
    let targets = c.targets
    if targets.isEmpty {
      return
    }
    let app = c.app
    do {
      let available = try await app.withProgress(tr("archive_command.checking")) { try await self.formats(c) }
      if available.isEmpty {
        await app.showError(unavailable(c))
        return
      }
      guard let choice = await app.askChoice(tr("archive_command.format_title"), available.map { $0.label }) else {
        return
      }
      let format = available[choice]
      let names = try await existing(c)
      let name = await askName(
        app,
        tr("archive_command.compress_title"),
        message: tr("archive_command.compress_message", ["count": targets.count, "place": place(c)]),
        // 最初にマークした項目の名前に拡張子を付ける。
        initial: "\(targets[0].entry.name)\(format.extension)",
        existing: names
      )
      guard let name else {
        return
      }
      do {
        try await app.withCancellableProgress(tr("archive_command.compressing"), cancellable: cancellable) { update in
          try await self.compress(c, targets, name, format) { done, total, item in
            update(tr("archive_command.compressing_count", ["done": done, "total": total, "name": item]))
          }
        }
        pane.marks.clear()
      } catch is CancellationError {
        // 作りかけの圧縮ファイルは compressPaths が消す。
        app.showStatus(tr("archive_command.compress_cancelled", ["name": name]))
      } catch {
        await app.showError(error)
      }
      await pane.load(focus: name)
    } catch {
      await app.showError(error)
    }
  }
}

/// ローカルのフォルダーに、この Mac の tar で圧縮する。形式はどれも使える。
final class LocalCompress: CompressCommand {
  override var cancellable: Bool { true }

  override func formats(_ c: CommandContext) async throws -> [ArchiveFormat] { ArchiveFormat.allCases }

  override func place(_ c: CommandContext) -> String { (c.pane as! LocalPane).dir }

  override func existing(_ c: CommandContext) async throws -> Set<String> { try await dirNames((c.pane as! LocalPane).dir) }

  override func compress(
    _ c: CommandContext, _ targets: [Mark], _ name: String, _ format: ArchiveFormat, progress: @escaping ArchiveProgress
  ) async throws {
    let pane = c.pane as! LocalPane
    try await compressPaths(targets.map { pane.pathOfMark($0) }, p.join(pane.dir, name), format, progress: progress)
  }
}

/// SSH の接続先のフォルダーに、接続先のコマンドで圧縮する。形式は、接続先にあるコマンドで使えるものだけ。
final class SshCompress: CompressCommand {
  override func formats(_ c: CommandContext) async throws -> [ArchiveFormat] {
    try await (c.pane as! SshPane).ssh!.archiveFormats()
  }

  override func unavailable(_ c: CommandContext) -> String {
    tr("archive_command.ssh_unavailable", ["host": (c.pane as! SshPane).ssh!.host])
  }

  override func place(_ c: CommandContext) -> String { (c.pane as! SshPane).location }

  override func existing(_ c: CommandContext) async throws -> Set<String> { (c.pane as! SshPane).names }

  override func compress(
    _ c: CommandContext, _ targets: [Mark], _ name: String, _ format: ArchiveFormat, progress: @escaping ArchiveProgress
  ) async throws {
    let pane = c.pane as! SshPane
    try await pane.ssh!.compress(targets.map { pane.pathOfMark($0) }, PathContext.posix.join(pane.dir, name), format)
  }
}

/// 開いた圧縮ファイル。中の項目と、丸ごと展開するしかた（引数は keepExisting と、項目を展開するたびに知らせる先）。
typealias OpenedArchive = (items: [ArchiveItem], extractAll: (_ keepExisting: Bool, _ progress: @escaping ArchiveProgress) async throws -> Void)

/// 対象の圧縮ファイルを、開いているフォルダーに展開する（U）。
/// 流れはここに書き、読み方と展開のしかたは、タブごとの継承クラスに書く。
class ExtractCommand: Command {
  override var writes: Bool { true }

  override var single: Bool { true }

  /// 展開先のフォルダー（小窓に出す）。
  func place(_ c: CommandContext) -> String { fatalError("place") }

  /// Esc で止められる（[CompressCommand.cancellable] と同じ）。
  var cancellable: Bool { false }

  /// 展開先のフォルダーにある名前。
  func existing(_ c: CommandContext) async throws -> Set<String> { fatalError("existing") }

  /// [target] の圧縮ファイルを開いて中を読む。読めなければ（道具がないときを含む）例外。
  func open(_ c: CommandContext, _ target: Mark) async throws -> OpenedArchive { fatalError("open") }

  override func run(_ c: CommandContext) async {
    let pane = c.pane
    guard let target = c.targets.first else {
      return
    }
    let entry = target.entry
    if entry.isDir || !isBrowsableArchive(entry.name) {
      return
    }
    let app = c.app
    do {
      let archive = try await app.withProgress(tr("archive_command.reading", ["name": entry.name])) { try await self.open(c, target) }
      // 最上位の名前が今のフォルダーにあれば、上書きするか聞く。
      let names = try await existing(c)
      let clashes = archiveChildren(archive.items, "").filter { names.contains($0.name) }.map { $0.name }
      var keepExisting = false
      if clashes.isEmpty {
        if !(await app.confirm(
          tr("archive_command.extract_title"),
          tr("archive_command.extract_confirm", ["name": entry.name, "place": place(c)]),
          yes: tr("archive_command.extract_yes")
        )) {
          return
        }
      } else {
        let shown = clashes.prefix(5).joined(separator: tr("archive_command.name_separator"))
        guard
          let choice = await app.askChoice(
            tr("archive_command.clash_title", ["names": shown + (clashes.count > 5 ? tr("archive_command.clash_more") : "")]),
            [
              tr("archive_command.overwrite"),
              tr("archive_command.keep_existing"),
            ])
        else {
          return
        }
        keepExisting = choice == 1
      }
      try await app.withCancellableProgress(tr("archive_command.extracting", ["name": entry.name]), cancellable: cancellable) { update in
        try await archive.extractAll(keepExisting) { done, total, item in
          update(tr("archive_command.extracting_count", ["archive": entry.name, "done": done, "total": total, "name": item]))
        }
      }
    } catch is CancellationError {
      app.showStatus(tr("archive_command.extract_cancelled", ["name": entry.name]))
    } catch {
      await app.showError(error)
    }
    await pane.load(focus: entry.name)
  }
}

/// ローカルの圧縮ファイルを、この Mac の tar で展開する。
final class LocalExtract: ExtractCommand {
  override var cancellable: Bool { true }

  override func place(_ c: CommandContext) -> String { (c.pane as! LocalPane).dir }

  override func existing(_ c: CommandContext) async throws -> Set<String> { try await dirNames((c.pane as! LocalPane).dir) }

  override func open(_ c: CommandContext, _ target: Mark) async throws -> OpenedArchive {
    let pane = c.pane as! LocalPane
    let archive = pane.pathOfMark(target)
    let items = try await listArchive(archive)
    return (
      items: items,
      extractAll: { keepExisting, progress in
        try await extractArchive(archive, items, pane.dir, keepExisting: keepExisting, progress: progress)
      }
    )
  }
}

/// SSH の接続先の圧縮ファイルを、接続先の tar・bsdtar・unzip で展開する。どれもなければ、そう出して止める。
final class SshExtract: ExtractCommand {
  override func place(_ c: CommandContext) -> String { (c.pane as! SshPane).location }

  override func existing(_ c: CommandContext) async throws -> Set<String> { (c.pane as! SshPane).names }

  override func open(_ c: CommandContext, _ target: Mark) async throws -> OpenedArchive {
    let pane = c.pane as! SshPane
    let archive = try await RemoteArchive.open(pane.ssh!, pane.pathOfMark(target))
    return (
      items: archive.items,
      // 接続先では進み具合を読まない（「処理中」だけ）。
      extractAll: { keepExisting, _ in try await archive.extractAll(pane.dir, keepExisting: keepExisting) }
    )
  }
}
