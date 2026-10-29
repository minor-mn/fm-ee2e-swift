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

/// パスを聞いて移る（Ctrl+L）。~ はホーム、相対パスは開いているフォルダーから。
/// 小窓と流れはここに書き、説明・ホーム・フォルダーの確かめ方はタブごとの継承クラスに書く。
class GoToPathCommand: Command {
  override var needsReady: Bool { false }

  /// 入力欄の説明。
  var prompt: String { fatalError("prompt") }

  func home(_ c: CommandContext) async throws -> String { fatalError("home") }

  func isDirectory(_ c: CommandContext, _ path: String) async throws -> Bool { fatalError("isDirectory") }

  override func run(_ c: CommandContext) async {
    let pane = c.pane as! PathPane
    guard let input = await c.app.input("ディレクトリへ移動", message: prompt, initial: pane.dirPath),
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
        await c.app.showError("ディレクトリがありません: \(target)")
        return
      }
      await pane.goToDir(target)
    } catch {
      await c.app.showError(error)
    }
  }
}

final class LocalGoToPath: GoToPathCommand {
  override var prompt: String { "パス（~ はホーム）" }

  override func home(_ c: CommandContext) async throws -> String { homeDir }

  override func isDirectory(_ c: CommandContext, _ path: String) async throws -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
  }
}

final class SshGoToPath: GoToPathCommand {
  override var prompt: String { "接続先のパス（~ はホーム）" }

  override func home(_ c: CommandContext) async throws -> String { try await (c.pane as! SshPane).ssh!.home() }

  override func isDirectory(_ c: CommandContext, _ path: String) async throws -> Bool {
    try await (c.pane as! SshPane).ssh!.isDirectory(path)
  }
}
