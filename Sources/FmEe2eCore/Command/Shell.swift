import Foundation


/// シェル（S）。コマンドを1行の入力欄で聞き（↑↓ でヒストリー）、開いているフォルダーで、枠の中の端末で実行する。
/// 終わったら出力を残して Enter を待ち（失敗したときは右下に終了コード）、一覧を読み直す。
/// 小窓と流れはここに書き、実行する場所・ヒストリー・補完・実行のしかたはタブごとの継承クラスに書く。
class ShellCommand: Command {
  override var needsReady: Bool { false }

  /// 使えるか。
  func available(_ c: CommandContext) -> Bool { true }

  /// 実行するタブ（終わったら読み直す）。
  func target(_ c: CommandContext) -> PathPane { fatalError("target") }

  /// 入力欄と枠の見出しに出す、実行する場所。
  func place(_ c: CommandContext) -> String { fatalError("place") }

  /// ↑↓ でたどるヒストリー（古い順）。
  func history(_ c: CommandContext) async throws -> [String] { fatalError("history") }

  /// 打ったコマンドをヒストリーに加える。
  func remember(_ c: CommandContext, _ command: String) async throws { fatalError("remember") }

  /// Tab の補完で候補を探す場所。
  func completion(_ c: CommandContext) -> CompletionSource { fatalError("completion") }

  /// [command] を実行するプログラムと引数、作業フォルダー。
  func commandLine(_ c: CommandContext, _ command: String) throws -> (String, [String], String?) { fatalError("commandLine") }

  override func run(_ c: CommandContext) async {
    if !available(c) {
      return
    }
    do {
      let place = self.place(c)
      let command = await c.app.input(
        "シェル",
        message: place,
        history: try await history(c),
        complete: { before in
          let result = try await completeShellWord(before, self.completion(c))
          return result.map { ($0.before, $0.candidates) }
        }
      )
      guard let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return
      }
      try await remember(c, command)
      let (executable, args, workingDirectory) = try commandLine(c, command)
      _ = await runInTerminal(c.app, "\(place) $ \(command)", executable, args, workingDirectory: workingDirectory)
      // 実行したコマンドがファイルを作ったり消したりした場合に備える。
      let pane = target(c)
      await pane.load(focus: pane.current?.name)
    } catch {
      await c.app.showError(error)
    }
  }
}

/// ローカルのフォルダーで実行する。右のローカルのタブではそのフォルダーで、Google Drive・Git のタブからは左のフォルダーで実行する。
/// ヒストリーはこの Mac のシェルのもの（打ったコマンドも追記する）。
final class LocalShell: ShellCommand {
  override func target(_ c: CommandContext) -> LocalPane { (c.pane as? LocalPane) ?? c.workspace.local }

  override func place(_ c: CommandContext) -> String { target(c).dir }

  override func history(_ c: CommandContext) async throws -> [String] { await loadShellHistory() }

  override func remember(_ c: CommandContext, _ command: String) async throws { try await appendShellHistory(command) }

  override func completion(_ c: CommandContext) -> CompletionSource { LocalCompletion(place(c)) }

  override func commandLine(_ c: CommandContext, _ command: String) throws -> (String, [String], String?) {
    let args = shellCommand(command)
    return (args[0], Array(args.dropFirst()), place(c))
  }
}

/// 接続先の開いているフォルダーで、接続先のログインシェルに実行させる。非対話なので、接続先のヒストリーには残らない。
/// ↑↓ は、このアプリで接続先ごとに打ったコマンドだけ（どこにも書き込まない）。
class SshShell: ShellCommand {
  override func target(_ c: CommandContext) -> SshPane { c.pane as! SshPane }

  private func ssh(_ c: CommandContext) -> Ssh { target(c).ssh! }

  override func place(_ c: CommandContext) -> String { "\(ssh(c).host):\(target(c).dir)" }

  override func history(_ c: CommandContext) async throws -> [String] { target(c).commandHistory[ssh(c).host] ?? [] }

  override func remember(_ c: CommandContext, _ command: String) async throws {
    let pane = target(c)
    let host = ssh(c).host
    var list = pane.commandHistory[host] ?? []
    if let index = list.firstIndex(of: command) {
      list.remove(at: index)
    }
    list.append(command)
    pane.commandHistory[host] = list
  }

  /// 名前は接続先に問い合わせる。コマンド名は接続先の `sh -c` の PATH から探す。
  override func completion(_ c: CommandContext) -> CompletionSource { RemoteCompletion(ssh(c), target(c).dir) }

  override func commandLine(_ c: CommandContext, _ command: String) throws -> (String, [String], String?) {
    (Ssh.executable, try ssh(c).commandArgs(target(c).dir, command), nil)
  }
}

/// 左が SSH のときの Git のタブのシェル。左の接続先の開いているフォルダーで実行する。
final class GitSshShell: SshShell {
  override func available(_ c: CommandContext) -> Bool { c.workspace.sshLeft.ssh != nil }

  override func target(_ c: CommandContext) -> SshPane { c.workspace.sshLeft }
}
