import Foundation

/// 選んでいるタブを読み直す（L）。
final class ReloadCommand: Command {
  override var needsReady: Bool { false }

  override func run(_ c: CommandContext) async { await c.pane.reload() }
}

/// 隠しファイルを出すかを切り替える（.）。
final class ToggleHiddenCommand: Command {
  override var needsReady: Bool { false }

  override func run(_ c: CommandContext) async {
    let pane = c.pane as! PathPane
    pane.showHidden = !pane.showHidden
    await pane.load()
  }
}

/// ホームへ移る（~）。ホームの場所はタブごとの継承クラスに書く。
class GoHomeCommand: Command {
  override var needsReady: Bool { false }

  func home(_ c: CommandContext) async throws -> String { fatalError("home") }

  override func run(_ c: CommandContext) async {
    do {
      await (c.pane as! PathPane).goToDir(try await home(c))
    } catch {
      await c.app.showError(error)
    }
  }
}

final class LocalGoHome: GoHomeCommand {
  override func home(_ c: CommandContext) async throws -> String { homeDir }
}

final class SshGoHome: GoHomeCommand {
  override func home(_ c: CommandContext) async throws -> String { try await (c.pane as! SshPane).ssh!.home() }
}

/// パスを聞いて移る（Ctrl+L）。~ はホーム、相対パスは開いているフォルダーから。↑↓ で、Ctrl+L で移ったフォルダーの履歴をたどる。
/// 小窓と流れはここに書き、説明・ホーム・フォルダーの確かめ方・履歴の分け方はタブごとの継承クラスに書く。
class GoToPathCommand: Command {
  override var needsReady: Bool { false }

  /// 入力欄の説明。
  var prompt: String { fatalError("prompt") }

  /// 履歴の分け方（ローカル・SSH の接続先・コンテナごと）。
  func historyKey(_ c: CommandContext) -> String { fatalError("historyKey") }

  func home(_ c: CommandContext) async throws -> String { fatalError("home") }

  func isDirectory(_ c: CommandContext, _ path: String) async throws -> Bool { fatalError("isDirectory") }

  override func run(_ c: CommandContext) async {
    let pane = c.pane as! PathPane
    let key = historyKey(c)
    guard
      let input = await c.app.input(
        tr("navigation.go_to_title"), message: prompt, initial: pane.dirPath, history: LocationHistory.load(key)),
      !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return
    }
    do {
      var path = input.trimmingCharacters(in: .whitespacesAndNewlines)
      if path == "~" || path.hasPrefix("~/") {
        path = expandHome(path, try await home(c))
      }
      let context = pane.context
      let target = context.normalize(context.isAbsolute(path) ? path : context.join(pane.dirPath, path))
      if !(try await isDirectory(c, target)) {
        c.app.showStatus(tr("navigation.not_found", ["path": target]))
        return
      }
      await pane.goToDir(target)
      do {
        try LocationHistory.remember(key, target)
      } catch {
        c.app.showStatus(tr("navigation.history_save_failed", ["error": errorMessage(error)]))
      }
    } catch {
      await c.app.showError(error)
    }
  }
}

/// Ctrl+L で移ったフォルダーの履歴（[file]）。分け方（[GoToPathCommand.historyKey]）ごとに、古い順の絶対パス。
/// 同じパスは1つにまとめて新しいほうへ寄せ、[limit] 件を超えたら古いものから捨てる。
enum LocationHistory {
  static var file: String { p.join(homeDir, ".config", "fm-ee2e", "location_history.json") }

  static let limit = 100

  /// 分け方ごとの履歴。読めなければ空。
  private static func loadAll(_ file: String) -> [String: [String]] {
    guard let data = FileManager.default.contents(atPath: file),
      let all = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
    else {
      return [:]
    }
    return all
  }

  /// [key] の履歴（古い順）。
  static func load(_ key: String, file: String = file) -> [String] { loadAll(file)[key] ?? [] }

  /// [key] の履歴に [path] を加えて保存する。
  static func remember(_ key: String, _ path: String, file: String = file) throws {
    var all = loadAll(file)
    var list = (all[key] ?? []).filter { $0 != path } + [path]
    if list.count > limit {
      list.removeFirst(list.count - limit)
    }
    all[key] = list
    let data = try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try FileManager.default.createDirectory(atPath: p.dirname(file), withIntermediateDirectories: true)
    try data.write(to: URL(fileURLWithPath: file), options: .atomic)
  }
}

final class LocalGoToPath: GoToPathCommand {
  override var prompt: String { tr("navigation.local_prompt") }

  override func historyKey(_ c: CommandContext) -> String { "local" }

  override func home(_ c: CommandContext) async throws -> String { homeDir }

  override func isDirectory(_ c: CommandContext, _ path: String) async throws -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
  }
}

final class SshGoToPath: GoToPathCommand {
  override var prompt: String { tr("navigation.ssh_prompt") }

  /// SSH は接続先ごと、Container はコンテナごと。
  override func historyKey(_ c: CommandContext) -> String {
    let pane = c.pane as! SshPane
    return "\(pane is ContainerPane ? "container" : "ssh"):\(pane.ssh?.host ?? "")"
  }

  override func home(_ c: CommandContext) async throws -> String { try await (c.pane as! SshPane).ssh!.home() }

  override func isDirectory(_ c: CommandContext, _ path: String) async throws -> Bool {
    try await (c.pane as! SshPane).ssh!.isDirectory(path)
  }
}
