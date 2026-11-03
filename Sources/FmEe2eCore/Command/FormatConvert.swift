import Foundation

/// 変換先のフォーマット。[name] は拡張子（「.」なし）を兼ねる。
struct FormatTarget {
  let name: String

  /// [from] のファイルを変換して [to] に書く（どちらも絶対パス）。
  let convert: (_ from: String, _ to: String) async throws -> Void
}

/// 変換元の拡張子（「.」なし・小文字）ごとの、変換先のフォーマット。起動時に一度だけ [locateConverters] で作る。
/// 変換のコマンドが見つからなければ空。
private(set) var formatConversions: [String: [FormatTarget]] = [:]

/// PATH から変換のコマンドを探し、変換できる組み合わせ（[formatConversions]）を作る。
func locateConverters() {
  var table: [String: [FormatTarget]] = [:]
  /// [command] が PATH にあれば、[sources] の拡張子から [target] への変換を足す。[arguments] は元と先から引数を作る。
  func add(_ command: String, _ sources: [String], _ target: String, _ arguments: @escaping (String, String) -> [String]) {
    // 見つからなければ、名前がそのまま返る。
    let path = resolveExecutable(command)
    if !path.contains("/") {
      return
    }
    for source in sources {
      table[source, default: []].append(FormatTarget(name: target) { from, to in try await runOrThrow(path, arguments(from, to)) })
    }
  }
  // WebP へは劣化させない（gif2webp は既定で劣化なし）。dwebp は PNG を書く。
  add("cwebp", ["png", "jpg", "jpeg", "tif", "tiff"], "webp") { ["-quiet", "-lossless", $0, "-o", $1] }
  add("gif2webp", ["gif"], "webp") { ["-quiet", $0, "-o", $1] }
  add("dwebp", ["webp"], "png") { ["-quiet", $0, "-o", $1] }
  // JPEG は劣化ありなので、画質を高くする（-q:v は 2 が高画質、既定はかなり粗い）。先があれば上書きしない（-n）。
  add("ffmpeg", ["webp"], "jpg") { ["-nostdin", "-loglevel", "error", "-n", "-i", $0, "-q:v", "2", $1] }
  formatConversions = table
}

/// 書き方が違うだけで同じフォーマットの拡張子（小文字）を、表の名前に揃える。
private let formatAliases = ["jpeg": "jpg", "tif": "tiff"]

/// [entry] の拡張子（「.」なし・小文字・[formatAliases] で揃えたもの）。変換できないもの（フォルダー・表にない拡張子）は nil。
private func formatKey(_ entry: Entry) -> String? {
  if entry.isDir {
    return nil
  }
  let ext = p.extension(entry.name)
  if ext.isEmpty {
    return nil
  }
  let key = String(ext.dropFirst()).lowercased()
  return formatConversions[key] == nil ? nil : formatAliases[key] ?? key
}

/// [entry] を変換できるフォーマット。フォルダーは変換しない。
func formatTargets(_ entry: Entry) -> [FormatTarget] {
  if entry.isDir {
    return []
  }
  let ext = p.extension(entry.name)
  return ext.isEmpty ? [] : formatConversions[String(ext.dropFirst()).lowercased()] ?? []
}

/// 対象のファイルを、別のフォーマットに変換する（F・F9）。対象は、マークがあればマークした全部、なければカーソルのファイル。
/// 変換先のフォーマットを選び、1つなら変換先の名前を聞く。2つ以上なら、名前は元の名前の拡張子を変えたものにする。
final class LocalFormat: Command {
  override var label: String { "Format" }

  override var writes: Bool { true }

  /// 対象がすべて変換できるファイルで、フォーマットが1種類のときだけ使える（フォルダーが混ざっていれば使えない）。
  override func available(_ pane: Pane) -> Bool {
    let targets = pane.targetsFor()
    guard let first = targets.first.flatMap({ formatKey($0.entry) }) else {
      return false
    }
    return targets.allSatisfy { formatKey($0.entry) == first }
  }

  override func run(_ c: CommandContext) async {
    guard let first = c.targets.first else {
      return
    }
    let formats = formatTargets(first.entry)
    if formats.isEmpty {
      return
    }
    guard let choice = await c.app.askChoice(tr("format.title"), formats.map { $0.name }) else {
      return
    }
    let format = formats[choice]
    let pane = c.pane as! LocalPane
    if c.targets.count > 1 {
      await convertAll(c, pane, format)
      return
    }
    // 隠しファイルを表示していないときも衝突させないよう、実際のフォルダーの中身で確認する。
    let existing: Set<String>
    do {
      existing = try await dirNames(first.parent)
    } catch {
      await c.app.showError(error)
      return
    }
    let initial = outputName(first.entry, format)
    // 拡張子の前までを選択した状態で開く。
    let name = await askName(c.app, tr("format.title"), message: tr("format.name"), initial: initial, selectStem: true, existing: existing)
    let from = p.absolute(pane.pathOfMark(first))
    await applyName(c.pane, name) { name in try await format.convert(from, p.join(p.absolute(first.parent), name)) }
  }

  /// 元の名前の拡張子を、[format] のものに変えた名前。
  private func outputName(_ entry: Entry, _ format: FormatTarget) -> String { "\(p.withoutExtension(entry.name)).\(format.name)" }

  /// マークした全部を、元の名前の拡張子を変えた名前で変換する。変換先にすでにある名前（変換先どうしの重なりを含む）が
  /// 1つでもあれば、何も変換しない。終わったらマークを外して読み直す。
  private func convertAll(_ c: CommandContext, _ pane: LocalPane, _ format: FormatTarget) async {
    let jobs = c.targets.map { (from: p.absolute(pane.pathOfMark($0)), to: p.join(p.absolute($0.parent), outputName($0.entry, format))) }
    var taken: [String] = []
    do {
      // 隠しファイルを表示していないときも衝突させないよう、実際のフォルダーの中身で確認する。
      var names: [String: Set<String>] = [:]
      var seen = Set<String>()
      for job in jobs {
        let dir = p.dirname(job.to)
        if names[dir] == nil {
          names[dir] = try await dirNames(dir)
        }
        let name = p.basename(job.to)
        if names[dir]!.contains(name) || !seen.insert(job.to).inserted {
          taken.append(name)
        }
      }
    } catch {
      await c.app.showError(error)
      return
    }
    if !taken.isEmpty {
      c.app.showStatus(tr("format.exists", ["names": taken.joined(separator: ", ")]))
      return
    }
    do {
      try await c.app.withProgress(tr("format.converting", ["count": jobs.count])) {
        for job in jobs {
          try await format.convert(job.from, job.to)
        }
      }
    } catch {
      await c.app.showError(error)
    }
    pane.marks.clear()
    await pane.load()
  }
}
