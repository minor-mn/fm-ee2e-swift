/// 対象のパーミッションを変える（A・F1）。最初の項目の値から始め、選んだ rwx をすべてに設定する。
/// 特殊ビットは最初の項目と同じ種類の項目にだけ設定する（ディレクトリはスティッキービット、ファイルは SUID・SGID）。
/// 小窓とビットの計算はここに書き、1項目の変え方はタブごとの継承クラスに書く。
class ChmodCommand: Command {
  override var label: String { "Attr" }

  override var writes: Bool { true }

  /// [mark] のパーミッションを [mode] にする。失敗したら例外。
  func setMode(_ c: CommandContext, _ mark: Mark, _ mode: Int) async throws { fatalError("setMode") }

  override func run(_ c: CommandContext) async {
    let targets = c.targets
    guard let firstMark = targets.first else {
      return
    }
    let first = firstMark.entry
    let label = targets.count == 1 ? first.name : "\(targets.count)項目"
    guard let bits = await c.app.askMode(label, first.mode ?? 0x1a4, isDir: first.isDir) else {
      return
    }
    let editable = first.isDir ? 0x200 : 0xc00
    var errors: [String] = []
    for mark in targets {
      let entry = mark.entry
      // 切り替えられない特殊ビットはそのまま残す。
      let keep = (entry.mode ?? 0) & 0xe00 & (entry.isDir == first.isDir ? ~editable : 0xe00)
      let set = entry.isDir == first.isDir ? bits & editable : 0
      do {
        try await setMode(c, mark, keep | set | (bits & 0x1ff))
      } catch {
        errors.append("\(entry.name): \(errorMessage(error))")
      }
    }
    if !errors.isEmpty {
      await c.app.showError(errors.joined(separator: "\n"))
    }
    c.pane.marks.clear()
    await c.pane.load()
  }
}

final class LocalChmod: ChmodCommand {
  /// BSD の chmod はモードの後の「--」をファイル名として扱うので、絶対パスで渡す。
  override func setMode(_ c: CommandContext, _ mark: Mark, _ mode: Int) async throws {
    try await runOrThrow("/bin/chmod", [String(mode, radix: 8), p.absolute((c.pane as! LocalPane).pathOfMark(mark))])
  }
}

final class SshChmod: ChmodCommand {
  override func setMode(_ c: CommandContext, _ mark: Mark, _ mode: Int) async throws {
    let pane = c.pane as! SshPane
    try await pane.ssh!.chmod(mode, pane.pathOfMark(mark))
  }
}
