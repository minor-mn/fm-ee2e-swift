/// ログアウト・切断（O）。確かめる小窓と流れはここに書き、文言としかたはタブごとの継承クラスに書く。
class SignOutCommand: Command {
  override var needsReady: Bool { false }

  /// 確かめる小窓の見出しと、実行するボタンの文言。
  var title: String { fatalError("title") }

  /// 確かめる小窓の本文。
  func message(_ c: CommandContext) -> String { fatalError("message") }

  /// 今ログアウト・切断できるか。
  func canSignOut(_ c: CommandContext) -> Bool { true }

  func signOut(_ c: CommandContext) async throws { fatalError("signOut") }

  override func run(_ c: CommandContext) async {
    if canSignOut(c), await c.app.confirm(title, message(c), yes: title) {
      do {
        try await signOut(c)
      } catch {
        await c.app.showError(error)
      }
    }
  }
}

/// 接続を切って、接続先の一覧に戻る。
final class SshDisconnect: SignOutCommand {
  override var title: String { "切断" }

  override func message(_ c: CommandContext) -> String { "\((c.pane as! SshPane).ssh!.host) との接続を切ります。" }

  override func canSignOut(_ c: CommandContext) -> Bool { (c.pane as! SshPane).ssh != nil }

  override func signOut(_ c: CommandContext) async throws { await (c.pane as! SshPane).disconnect() }
}
