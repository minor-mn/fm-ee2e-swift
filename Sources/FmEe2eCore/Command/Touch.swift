/// 名前を聞いて touch する（T・F5）。なければ空のファイルを作り、あれば更新日時を今にする。
/// 名前を聞く小窓と流れはここに書き、touch のしかたはタブごとの継承クラスに書く。
class TouchCommand: Command {
  override var label: String { "Touch" }

  override var writes: Bool { true }

  /// 開いているフォルダーの [name] を touch する。
  func touch(_ c: CommandContext, _ name: String) async throws { fatalError("touch") }

  override func run(_ c: CommandContext) async {
    await applyName(c.pane, await askName(c.app, "touch", message: tr("touch.message"))) { name in try await self.touch(c, name) }
  }
}

final class LocalTouch: TouchCommand {
  /// 「-」で始まる名前をオプションと誤認させないよう、絶対パスで渡す。
  override func touch(_ c: CommandContext, _ name: String) async throws {
    try await runOrThrow("/usr/bin/touch", [p.join(p.absolute((c.pane as! LocalPane).dir), name)])
  }
}

final class SshTouch: TouchCommand {
  override func touch(_ c: CommandContext, _ name: String) async throws {
    let pane = c.pane as! SshPane
    try await pane.ssh!.touch(PathContext.posix.join(pane.dir, name))
  }
}
