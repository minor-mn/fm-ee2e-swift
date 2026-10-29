/// 対象を、形式と名前を聞いて開いているフォルダーに圧縮する（Z）。
/// 流れはここに書き、使える形式と圧縮のしかたは、タブごとの継承クラスに書く。
class CompressCommand: Command {
  override var writes: Bool { true }

  /// 使える形式。
  func formats(_ c: CommandContext) async throws -> [ArchiveFormat] { fatalError("formats") }

  /// どの形式も使えないときに出す文。
  func unavailable(_ c: CommandContext) -> String { "圧縮できません。" }

  /// 圧縮先のフォルダー（小窓に出す）。
  func place(_ c: CommandContext) -> String { fatalError("place") }

  /// 圧縮先のフォルダーにある名前。
  func existing(_ c: CommandContext) async throws -> Set<String> { fatalError("existing") }

  /// [targets] を、圧縮先のフォルダーの [name] に [format] で圧縮する。
  func compress(_ c: CommandContext, _ targets: [Mark], _ name: String, _ format: ArchiveFormat) async throws {
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
      let available = try await app.withProgress("確認中…") { try await self.formats(c) }
      if available.isEmpty {
        await app.showError(unavailable(c))
        return
      }
      guard let choice = await app.askChoice("圧縮の形式", available.map { $0.label }) else {
        return
      }
      let format = available[choice]
      let names = try await existing(c)
      let name = await askName(
        app,
        "圧縮",
        message: "\(targets.count)項目を \(place(c)) に圧縮します。ファイル名",
        // 最初にマークした項目の名前に拡張子を付ける。
        initial: "\(targets[0].entry.name)\(format.extension)",
        existing: names
      )
      guard let name else {
        return
      }
      do {
        try await app.withProgress("圧縮中…") { try await self.compress(c, targets, name, format) }
        pane.marks.clear()
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
  override func formats(_ c: CommandContext) async throws -> [ArchiveFormat] { ArchiveFormat.allCases }

  override func place(_ c: CommandContext) -> String { (c.pane as! LocalPane).dir }

  override func existing(_ c: CommandContext) async throws -> Set<String> { try await dirNames((c.pane as! LocalPane).dir) }

  override func compress(_ c: CommandContext, _ targets: [Mark], _ name: String, _ format: ArchiveFormat) async throws {
    let pane = c.pane as! LocalPane
    try await compressPaths(targets.map { pane.pathOfMark($0) }, p.join(pane.dir, name), format)
  }
}

/// SSH の接続先のフォルダーに、接続先のコマンドで圧縮する。形式は、接続先にあるコマンドで使えるものだけ。
final class SshCompress: CompressCommand {
  override func formats(_ c: CommandContext) async throws -> [ArchiveFormat] {
    try await (c.pane as! SshPane).ssh!.archiveFormats()
  }

  override func unavailable(_ c: CommandContext) -> String {
    "\((c.pane as! SshPane).ssh!.host) には zip も tar（gzip・xz）もないので、圧縮できません。"
  }

  override func place(_ c: CommandContext) -> String { (c.pane as! SshPane).location }

  override func existing(_ c: CommandContext) async throws -> Set<String> { (c.pane as! SshPane).names }

  override func compress(_ c: CommandContext, _ targets: [Mark], _ name: String, _ format: ArchiveFormat) async throws {
    let pane = c.pane as! SshPane
    try await pane.ssh!.compress(targets.map { pane.pathOfMark($0) }, PathContext.posix.join(pane.dir, name), format)
  }
}

/// 開いた圧縮ファイル。中の項目と、丸ごと展開するしかた（引数は keepExisting）。
typealias OpenedArchive = (items: [ArchiveItem], extractAll: (_ keepExisting: Bool) async throws -> Void)

/// 対象の圧縮ファイルを、開いているフォルダーに展開する（U）。
/// 流れはここに書き、読み方と展開のしかたは、タブごとの継承クラスに書く。
class ExtractCommand: Command {
  override var writes: Bool { true }

  override var single: Bool { true }

  /// 展開先のフォルダー（小窓に出す）。
  func place(_ c: CommandContext) -> String { fatalError("place") }

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
      let archive = try await app.withProgress("「\(entry.name)」を読み込み中…") { try await self.open(c, target) }
      // 最上位の名前が今のフォルダーにあれば、上書きするか聞く。
      let names = try await existing(c)
      let clashes = archiveChildren(archive.items, "").filter { names.contains($0.name) }.map { $0.name }
      var keepExisting = false
      if clashes.isEmpty {
        if !(await app.confirm("展開", "「\(entry.name)」を \(place(c)) に展開します。", yes: "展開")) {
          return
        }
      } else {
        let shown = clashes.prefix(5).joined(separator: "、")
        guard
          let choice = await app.askChoice(
            "同じ名前があります（\(shown)\(clashes.count > 5 ? " ほか" : "")）",
            [
              "上書きする",
              "今あるファイルは残す",
            ])
        else {
          return
        }
        keepExisting = choice == 1
      }
      try await app.withProgress("「\(entry.name)」を展開中…") { try await archive.extractAll(keepExisting) }
    } catch {
      await app.showError(error)
    }
    await pane.load(focus: entry.name)
  }
}

/// ローカルの圧縮ファイルを、この Mac の tar で展開する。
final class LocalExtract: ExtractCommand {
  override func place(_ c: CommandContext) -> String { (c.pane as! LocalPane).dir }

  override func existing(_ c: CommandContext) async throws -> Set<String> { try await dirNames((c.pane as! LocalPane).dir) }

  override func open(_ c: CommandContext, _ target: Mark) async throws -> OpenedArchive {
    let pane = c.pane as! LocalPane
    let archive = pane.pathOfMark(target)
    let items = try await listArchive(archive)
    return (
      items: items,
      extractAll: { keepExisting in
        try await extractArchive(archive, items, pane.dir, keepExisting: keepExisting)
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
      extractAll: { keepExisting in try await archive.extractAll(pane.dir, keepExisting: keepExisting) }
    )
  }
}
