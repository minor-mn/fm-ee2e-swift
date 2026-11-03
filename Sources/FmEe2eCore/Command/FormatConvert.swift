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
  // 見つからなければ、名前がそのまま返る。
  let cwebp = resolveExecutable("cwebp")
  if cwebp.contains("/") {
    table["png", default: []].append(FormatTarget(name: "webp") { from, to in try await runOrThrow(cwebp, ["-quiet", "-lossless", from, "-o", to]) })
  }
  formatConversions = table
}

/// [entry] を変換できるフォーマット。フォルダーは変換しない。
func formatTargets(_ entry: Entry) -> [FormatTarget] {
  if entry.isDir {
    return []
  }
  let ext = p.extension(entry.name)
  return ext.isEmpty ? [] : formatConversions[String(ext.dropFirst()).lowercased()] ?? []
}

/// カーソルのファイルを、別のフォーマットに変換する（F・F9）。変換先のフォーマットを選び、変換先の名前を聞く。
final class LocalFormat: Command {
  override var label: String { "Format" }

  override var writes: Bool { true }

  override var cursorOnly: Bool { true }

  /// カーソルの項目が、変換できるファイルのときだけ使える。
  override func available(_ pane: Pane) -> Bool {
    pane.cursorTargets().first.map { !formatTargets($0.entry).isEmpty } ?? false
  }

  override func run(_ c: CommandContext) async {
    guard let target = c.targets.first else {
      return
    }
    let formats = formatTargets(target.entry)
    if formats.isEmpty {
      return
    }
    guard let choice = await c.app.askChoice(tr("format.title"), formats.map { $0.name }) else {
      return
    }
    let format = formats[choice]
    // 隠しファイルを表示していないときも衝突させないよう、実際のフォルダーの中身で確認する。
    let existing: Set<String>
    do {
      existing = try await dirNames(target.parent)
    } catch {
      await c.app.showError(error)
      return
    }
    let initial = "\(p.withoutExtension(target.entry.name)).\(format.name)"
    // 拡張子の前までを選択した状態で開く。
    let name = await askName(c.app, tr("format.title"), message: tr("format.name"), initial: initial, selectStem: true, existing: existing)
    let from = p.absolute((c.pane as! LocalPane).pathOfMark(target))
    await applyName(c.pane, name) { name in try await format.convert(from, p.join(p.absolute(target.parent), name)) }
  }
}
