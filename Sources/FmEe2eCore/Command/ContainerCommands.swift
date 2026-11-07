final class ContainerEnter: Command {
  override var needsReady: Bool { false }
  override func run(_ c: CommandContext) async {
    if !c.pane.loading { await (c.pane as! ContainerPane).enter() }
  }
}

/// Container のローカルとの往来。既存の確認・同名処理・一時領域での置き換えを共有する。
final class ContainerUpload: LocalScp {
  let container: ContainerPane
  let local: LocalPane
  init(_ container: ContainerPane, _ local: LocalPane) { self.container = container; self.local = local }
  override var label: String { "Container G" }
  override func near(_ c: CommandContext) -> Pane { local }
  override func remotePane(_ c: CommandContext) -> SshPane { container }
  override func transfer(_ remote: Ssh, _ from: String, _ to: String) async throws -> ProcResult {
    try await (remote as! ContainerConnection).copyTar(from, to, upload: true)
  }
}

final class ContainerDownload: SshScp {
  let container: ContainerPane
  let local: LocalPane
  init(_ container: ContainerPane, _ local: LocalPane) { self.container = container; self.local = local }
  override var label: String { "Container G" }
  override func near(_ c: CommandContext) -> Pane { local }
  override func remotePane(_ c: CommandContext) -> SshPane { container }
  override func transfer(_ remote: Ssh, _ from: String, _ to: String) async throws -> ProcResult {
    try await (remote as! ContainerConnection).copyTar(from, to, upload: false)
  }
}

/// 選択中の左右のタブから向きを決める。Container とホストのローカルの組だけで使える。
final class ContainerTransfer: Command {
  init(upload: Bool) { self.upload = upload }
  let upload: Bool
  override var label: String { "Container G" }
  override var needsReady: Bool { false }
  override func run(_ c: CommandContext) async {
    let other = c.workspace.active === c.workspace.left ? c.workspace.right : c.workspace.left
    let container = (c.pane as? ContainerPane) ?? (other as? ContainerPane)
    let local = (c.pane as? LocalPane) ?? (other as? LocalPane)
    guard let container, let local else { c.app.showStatus(tr("container.transfer_local_only")); return }
    guard container.ready, local.ready, container.ssh != nil, await container.checkWritable() else { return }
    await runCommand(upload ? ContainerUpload(container, local) : ContainerDownload(container, local), c.workspace)
  }
}

final class ContainerAction: Command {
  init(_ action: String) { self.action = action }
  let action: String
  override var label: String {
    switch action {
    case "create": "Create"
    case "start": "Up"
    case "stop": "Stop"
    case "delete": "Delete"
    default: ""
    }
  }
  override var needsReady: Bool { false }
  override func available(_ pane: Pane) -> Bool {
    (pane as? ContainerPane)?.canPerformContainerAction(action) ?? false
  }
  override func run(_ c: CommandContext) async { await (c.pane as! ContainerPane).containerAction(action, targets: c.targets) }
}

final class ComposeFiles: Command {
  override var label: String { "Compose" }
  override var needsReady: Bool { false }
  override func run(_ c: CommandContext) async { await (c.pane as! ContainerPane).chooseComposeFiles() }
}

/// カーソルのコンテナの作成設定を変える（A・F5）。
final class ContainerSettingsCommand: Command {
  override var label: String { "Attr" }
  override var needsReady: Bool { false }
  override func available(_ pane: Pane) -> Bool { (pane as? ContainerPane)?.canEditSettings ?? false }
  override func run(_ c: CommandContext) async { await (c.pane as! ContainerPane).editSettings() }
}

/// コンテナの一覧のメニュー（F12）。表示の切り替え・ログ・イメージの削除。
final class ContainerLogs: Command {
  override var label: String { "Container" }
  override var needsReady: Bool { false }
  override func available(_ pane: Pane) -> Bool { (pane as? ContainerPane)?.canShowMenu ?? false }
  override func run(_ c: CommandContext) async { await (c.pane as! ContainerPane).showMenu() }
}
