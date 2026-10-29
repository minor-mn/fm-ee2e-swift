import Foundation

/// C・M で選んだ項目を、開いているフォルダーに貼り付ける（P）。
/// 流れはここに書き、どのクリップを受け付けるかと、貼り付け方はタブごとの継承クラスに書く。
class PasteCommand: Command {
  override var writes: Bool { true }

  /// このタブに貼り付けられる種類のクリップか。
  func accepts(_ c: CommandContext, _ clip: Clip) -> Bool { fatalError("accepts") }

  /// 貼り付けてよいかを確かめる。だめなら理由を出して false。
  func check(_ c: CommandContext, _ clip: Clip) async -> Bool { true }

  /// [clip] を貼り付け、最初に貼り付けた名前を返す。
  func paste(_ c: CommandContext, _ clip: Clip) async throws -> String? { fatalError("paste") }

  override func run(_ c: CommandContext) async {
    guard let clip = c.workspace.clip else {
      return
    }
    if !accepts(c, clip) {
      await c.app.showError("ローカルとGoogle Drive・SSH の間は G で転送してください。")
      return
    }
    if !(await check(c, clip)) {
      return
    }
    let focus: String?
    do {
      focus = try await paste(c, clip)
    } catch {
      await c.app.showError(error)
      return
    }
    // 移動した項目は元の場所にないので、もう一度は貼り付けられない。
    if clip.move {
      c.workspace.clip = nil
    }
    await c.pane.load(focus: focus)
  }

  /// 途中のエラーをまとめて出す。
  fileprivate static func withErrors(
    _ c: CommandContext,
    _ move: Bool,
    _ body: (_ conflicts: Conflicts, _ errors: inout [String]) async throws -> String?
  ) async throws -> String? {
    let conflicts = Conflicts { path in await askConflict(c.app, path) }
    var errors: [String] = []
    var first: String?
    do {
      first = try await c.app.withProgress(move ? "移動中…" : "コピー中…") { try await body(conflicts, &errors) }
    } catch is PlanCancelled {
      // 途中で中止。済んだ分はそのまま。
    }
    if !errors.isEmpty {
      await c.app.showError(errors.joined(separator: "\n"))
    }
    return first
  }
}

/// パスで扱う場所（ローカル・SSH の接続先）への貼り付け。同名は確かめ、上書きでは今あるものを片付けてから置く。
/// 違い（パスの書き方・名前の一覧・片付け方・移し方）は継承クラスに書く。
class PathPasteCommand: PasteCommand {
  var context: PathContext { fatalError("context") }

  /// 貼り付ける先のフォルダー。
  func dest(_ c: CommandContext) -> String { fatalError("dest") }

  /// [clip] の項目のパス。
  func paths(_ clip: Clip) -> [String] { fatalError("paths") }

  /// [dir] の項目の名前（隠しファイルを含む）。
  func names(_ c: CommandContext, _ dir: String) async throws -> Set<String> { fatalError("names") }

  /// 同名の確認で見せる場所。
  func display(_ c: CommandContext, _ path: String) -> String { path }

  /// 上書きされる側を片付ける。
  func replace(_ c: CommandContext, _ path: String) async throws { fatalError("replace") }

  func moveItem(_ c: CommandContext, _ from: String, _ to: String) async throws { fatalError("moveItem") }

  func copyItem(_ c: CommandContext, _ from: String, _ to: String) async throws { fatalError("copyItem") }

  override func paste(_ c: CommandContext, _ clip: Clip) async throws -> String? {
    let move = clip.move
    let dest = self.dest(c)
    return try await PasteCommand.withErrors(c, move) { conflicts, errors in
      var first: String?
      var existing = try await names(c, dest)
      for from in paths(clip) {
        let name = context.basename(from)
        if move && context.equals(context.dirname(from), dest) {
          continue
        }
        if context.equals(from, dest) || context.isWithin(from, dest) {
          errors.append("\(name): フォルダーをその中には\(move ? "移動" : "コピー")できません。")
          continue
        }
        var target = name
        var replaced: String?
        if existing.contains(name) {
          let destPath = context.join(dest, name)
          switch try await conflicts.ask(display(c, destPath)) {
          case .skip:
            continue
          case .overwrite:
            // 自分自身への上書きは何もしない。
            if context.equals(from, destPath) {
              continue
            }
            replaced = destPath
          case .rename:
            target = uniqueName(name, existing)
          }
        }
        do {
          if let replaced {
            try await replace(c, replaced)
          }
          let to = context.join(dest, target)
          if move {
            try await moveItem(c, from, to)
          } else {
            try await copyItem(c, from, to)
          }
          existing.insert(target)
          first = first ?? target
        } catch {
          errors.append("\(name): \(errorMessage(error))")
        }
      }
      return first
    }
  }
}

/// 上書きされる側はゴミ箱に移す。
final class LocalPaste: PathPasteCommand {
  override func accepts(_ c: CommandContext, _ clip: Clip) -> Bool { clip is LocalClip }

  override var context: PathContext { p }

  override func dest(_ c: CommandContext) -> String { (c.pane as! LocalPane).dir }

  override func paths(_ clip: Clip) -> [String] { (clip as! LocalClip).paths }

  override func names(_ c: CommandContext, _ dir: String) async throws -> Set<String> {
    try await dirNames((c.pane as! LocalPane).dir)
  }

  override func replace(_ c: CommandContext, _ path: String) async throws { try await moveToTrash(path) }

  override func moveItem(_ c: CommandContext, _ from: String, _ to: String) async throws { try await movePath(from, to) }

  override func copyItem(_ c: CommandContext, _ from: String, _ to: String) async throws { try await copyPath(from, to) }
}

/// コピー・移動した接続と同じ接続先にだけ貼り付ける。上書きされる側は消す（ゴミ箱はない）。
final class SshPaste: PathPasteCommand {
  override func accepts(_ c: CommandContext, _ clip: Clip) -> Bool { clip is SshClip }

  override func check(_ c: CommandContext, _ clip: Clip) async -> Bool {
    if (clip as! SshClip).ssh !== (c.pane as! SshPane).ssh {
      await c.app.showError("コピー・移動した接続とは別の接続です。")
      return false
    }
    return true
  }

  override var context: PathContext { .posix }

  override func dest(_ c: CommandContext) -> String { (c.pane as! SshPane).dir }

  override func paths(_ clip: Clip) -> [String] { (clip as! SshClip).paths }

  /// 一覧を読んだときの名前（隠しファイルを含む）。
  override func names(_ c: CommandContext, _ dir: String) async throws -> Set<String> { (c.pane as! SshPane).names }

  override func display(_ c: CommandContext, _ path: String) -> String { "\((c.pane as! SshPane).ssh!.host):\(path)" }

  override func replace(_ c: CommandContext, _ path: String) async throws {
    try await (c.pane as! SshPane).ssh!.remove([path])
  }

  override func moveItem(_ c: CommandContext, _ from: String, _ to: String) async throws {
    try await (c.pane as! SshPane).ssh!.move(from, to)
  }

  override func copyItem(_ c: CommandContext, _ from: String, _ to: String) async throws {
    try await (c.pane as! SshPane).ssh!.copy(from, to)
  }
}

/// Google Drive の中での貼り付け。暗号化したまま中身ごとコピー・移動し、名前は貼り付け先で暗号化し直す。
/// 同名は復号した名前で確かめ、上書きでは新しいものを置いてから今あるものをゴミ箱に移す。
/// コピーで手元にできた中身（読んだ元と、できた複製）は、Drive に上がり終えたら外す。
final class DrivePaste: PasteCommand {
  override func accepts(_ c: CommandContext, _ clip: Clip) -> Bool { clip is DriveClip }

  override func paste(_ c: CommandContext, _ clip: Clip) async throws -> String? {
    let pane = c.pane as! DrivePane
    let dest = pane.dirPath
    let move = clip.move
    return try await PasteCommand.withErrors(c, move) { conflicts, errors in
      var first: String?
      var existing = try await pane.itemsIn(dest)
      for item in (clip as! DriveClip).items {
        let name = item.name
        if move && p.equals(p.dirname(item.path), dest) {
          continue
        }
        if item.isDir && (p.equals(item.path, dest) || p.isWithin(item.path, dest)) {
          errors.append("\(name): フォルダーをその中には\(move ? "移動" : "コピー")できません。")
          continue
        }
        var target = name
        var replaced: String?
        if let source = existing[name] {
          let sourcePath: String
          switch source {
          case let file as LocalFile: sourcePath = file.file
          case let dir as LocalDir: sourcePath = dir.directory
          default: fatalError("LocalSource")
          }
          switch try await conflicts.ask("Google Drive / \(await pane.displayOf(dest)) / \(name)") {
          case .skip:
            continue
          case .overwrite:
            // 自分自身への上書きは何もしない。
            if p.equals(sourcePath, item.path) {
              continue
            }
            replaced = sourcePath
          case .rename:
            target = uniqueName(name, Set(existing.keys))
          }
        }
        do {
          let to = try await pane.encryptedPath(dest, target, isFolder: item.isDir)
          if move {
            try await movePath(item.path, to)
          } else {
            try await copyPath(item.path, to)
            pane.evictLater([item.path, to])
          }
          if let replaced {
            try await moveToTrash(replaced)
          }
          existing[target] = item.isDir ? LocalDir(to) as LocalSource : LocalFile(to, 0)
          first = first ?? target
        } catch {
          errors.append("\(name): \(errorMessage(error))")
        }
      }
      return first
    }
  }
}
