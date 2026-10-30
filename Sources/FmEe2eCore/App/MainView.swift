/// FD風の2画面。左はローカル・SSH の接続先（Shift+Tab で切り替える）、
/// 右は Google Drive・git status・SSH の接続先・iCloud Drive・ローカル（Tab で切り替える）。
/// 右の窓に出すタブは設定ファイル（[AppConfig]）で選び、false のタブは使わない（確かめもしない）。
/// 左の SSH は、右の SSH のタブが on のときだけ使える。
final class MainView: View, Workspace {
  init(_ app: App, config: AppConfig = AppConfig()) {
    self.app = app
    self.config = config
    local = LocalPane(app)
    localRight = RightLocalPane(app)
    icloud = ICloudPane(app)
    drive = DrivePane(app)
    ssh = SshPane(app)
    sshLeft = SshPane(app)
    noTab = NoTabPane(app, ["main_view.no_tab.title", "main_view.no_tab.hint"])
    gitChecking = NoTabPane(app, ["main_view.git_checking"])
    rightMode = Self.startMode(config)
    preview = PreviewOverlay(app)
    // 左の SSH を切る（別の接続先につなぎ直すときを含む）前に、それを経由する右の SSH を切る。
    sshLeft.beforeDisconnect = { [unowned self] connection in
      if ssh.ssh?.via === connection {
        await ssh.follow(nil, waiting: leftMode == .ssh)
      }
    }
    Task { await local.load() }
    let (driveChecked, gitFound) = startTabs(config.rightTabs)
    Task { await chooseStartRight(driveChecked, gitFound) }
  }

  /// 右の窓のタブ [modes] を使い始める（確かめ・読み込み）。Google Drive と git の確かめの Task を返す。
  @discardableResult
  private func startTabs(_ modes: [RightMode]) -> (Task<Void, Never>, Task<Void, Never>) {
    let driveChecked = Task { if modes.contains(.drive) { await drive.check() } }
    if modes.contains(.ssh) { Task { await ssh.load() } }
    if modes.contains(.icloud) { Task { await icloud.check() } }
    if modes.contains(.local) { Task { await localRight.load() } }
    let gitFound = Task {
      if modes.contains(.git) && gitPane == nil {
        let found = (try? await Git.locate()) ?? nil
        gitLocated = true
        if let found {
          gitPane = GitPane(app, found)
        }
        app.requestRender()
      }
    }
    return (driveChecked, gitFound)
  }

  /// 読み直した設定ファイル [next] を反映する。新しく使うタブは使い始め、右の窓のタブが使えなくなっていれば切り替える。
  func apply(_ next: AppConfig) {
    let added = next.rightTabs.filter { !config.rightTabs.contains($0) }
    config = next
    startTabs(added)
    let modes = rightModes
    if !modes.contains(rightMode), let first = modes.first {
      rightMode = modes.contains(.local) ? .local : first
      if showGit {
        Task { await showGitPane() }
      }
    }
    app.requestRender()
  }

  /// 設定ファイルの内容。
  private(set) var config: AppConfig

  /// 右の窓に [mode] のタブを出すか（設定ファイルで true か）。
  private func uses(_ mode: RightMode) -> Bool { config.rightTabs.contains(mode) }

  /// Tab で切り替える右の窓のタブ。git は見つかったときだけ。左が SSH のときは、ローカル・git・SSH だけ。
  private var rightModes: [RightMode] {
    config.rightTabs.filter { mode in
      (mode != .git || gitPane != nil) && (leftMode == .local || [.local, .git, .ssh].contains(mode))
    }
  }

  /// 起動したときの右のタブ。ローカルが on ならローカル、off なら on のうち最初のタブ。
  private static func startMode(_ config: AppConfig) -> RightMode {
    config.rightTabs.contains(.local) ? .local : config.rightTabs.first ?? .local
  }

  /// 起動時の右の窓。ローカルが off で、最初のタブが Google Drive で、Google ドライブ for デスクトップのフォルダーがないか、
  /// 使えなかった（読み込みで失敗した）ときは Git にする。最初のタブが git で、git が見つからなければ次のタブにする。
  /// それまでに Tab で切り替えていれば、そのままにする。
  private func chooseStartRight(_ driveChecked: Task<Void, Never>, _ gitFound: Task<Void, Never>) async {
    // 使えるなら、check は最初の一覧の読み込みまで待つ。
    await driveChecked.value
    await gitFound.value
    if rightChosen {
      return
    }
    let unusable = drive.state == .notInstalled || (drive.state == .ready && drive.error != nil)
    if rightMode == .drive && unusable && gitPane != nil {
      rightMode = .git
    } else if rightMode == .git && gitPane == nil {
      rightMode = rightModes.first ?? rightMode
    }
    if showGit {
      await showGitPane()
    }
    app.requestRender()
  }

  /// git の窓に、左の窓のフォルダーのリポジトリを出す。左が SSH なら接続先のリポジトリ。
  private func showGitPane() async {
    switch (leftMode, sshLeft.ssh) {
    case (.local, _): await gitPane!.show(local.dir)
    case (.ssh, let remote?): await gitPane!.showRemote(remote, sshLeft.dir)
    case (.ssh, nil): await gitPane!.showNotice([tr("main_view.choose_left_ssh")])
    }
  }

  /// Tab で右の窓を選んだ（起動時の右の窓を変えない）。
  private var rightChosen = false

  let app: App
  let local: LocalPane
  let localRight: LocalPane
  let icloud: ICloudPane
  let drive: DrivePane

  /// SSH の窓。つなぐ前は ~/.ssh/config の Host を並べる。
  let ssh: SshPane
  let sshLeft: SshPane
  var rightActive = false

  var gitPane: GitPane?

  var leftMode = LeftMode.local

  var rightMode: RightMode

  /// 右の窓に出すタブがないときの右の窓。
  private let noTab: NoTabPane

  /// git を探している間の右の窓。
  private let gitChecking: NoTabPane

  /// git を探し終えた。
  private var gitLocated = false

  /// 右の窓に git を出している。
  var showGit: Bool { rightMode == .git && gitPane != nil }

  var clip: Clip?

  /// 操作中（ダイアログを含む非同期の処理）。その間のキーは無視する。
  private var busy = false

  /// 左のローカルの窓の画像・動画を、右の窓に重ねて出す（V）。
  private let preview: PreviewOverlay

  var left: Pane {
    switch leftMode {
    case .local: local
    case .ssh: sshLeft
    }
  }

  var right: Pane {
    if !rightModes.contains(rightMode) {
      return rightMode == .git && !gitLocated ? gitChecking : noTab
    }
    switch rightMode {
    case .git: return gitPane!
    case .ssh: return ssh
    case .drive: return drive
    case .icloud: return icloud
    case .local: return localRight
    }
  }

  var active: Pane { rightActive ? right : left }

  /// すべての窓。
  private var panes: [Pane] { [local, sshLeft, drive] + (gitPane.map { [$0] } ?? []) + [ssh, icloud, localRight] }

  // ---- 描画 ----

  func draw(_ screen: Screen) {
    let w = screen.width
    let h = screen.height
    if w < 40 || h < 15 {
      screen.text(0, 0, tr("main_view.terminal_too_small"), Style(fg: Palette.error))
      return
    }
    // 上は枠で囲んだ4行（タイトル入りの線、容量、所有者、下の線）。
    // 上の帯は、枠の中だけに背景（appearance.window.header）を塗れるよう、重ねた画面に描く。
    screen.layer(0, 0, w, 4, theme: .window, framed: true, fill: Theme.active.colors.header) { s in
      drawHeader(s)
      drawUsage(s, 1, active)
      drawOwnership(s, 2, active)
    }
    let leftWidth = w / 2
    // 下から、ファンクションキー、空白、案内、マークの4行。
    let paneHeight = h - 8
    app.activeTheme = active.themeKey
    // プレビューは、選んでいる窓と反対側の窓に重ねる。
    let target = previewTarget()
    // 窓は、タブの見た目（GUI 版では文字の大きさも）で描く。
    screen.layer(0, 4, leftWidth, paneHeight, theme: left.themeKey, framed: true) { s in
      left.draw(s, 0, 0, s.width, s.height, focused: !rightActive, accentBorder: !rightActive)
      if rightActive, let (source, entry, kind) = target {
        preview.draw(s, source, entry, kind, 0, 0, s.width, s.height)
      }
    }
    // 右の窓（Google Drive・git・SSH・iCloud Drive）は、選んでいなくても色で見分けられるよう、いつも自分の色の枠にする。
    screen.layer(leftWidth, 4, w - leftWidth, paneHeight, theme: right.themeKey, framed: true) { s in
      right.draw(s, 0, 0, s.width, s.height, focused: rightActive, accentBorder: true)
      if !rightActive, let (source, entry, kind) = target {
        preview.draw(s, source, entry, kind, 0, 0, s.width, s.height)
      }
    }
    if let marked = panes.first(where: { !$0.marks.isEmpty }) {
      drawMarks(screen, h - 4, marked, marked === local || marked === sshLeft ? tr("main_view.side.left") : tr("main_view.side.right"))
    }
    drawInfo(screen, h - 3)
    drawFunctionKeyBar(screen, h - 1)
  }

  /// 選んでいる窓（ローカル・iCloud Drive・SSH）でカーソルが画像か動画（SSH は画像だけ）に乗っていて、
  /// プレビューを反対側の窓に重ねられるとき、その窓と項目と種類。左のローカルで選んでいて右が SSH のときは重ねない。
  private func previewTarget() -> (Pane, Entry, PreviewKind)? {
    let source: Pane?
    if rightActive {
      switch rightMode {
      case .local: source = localRight
      case .icloud: source = icloud
      case .ssh: source = ssh
      default: source = nil
      }
    } else {
      source = leftMode == .ssh ? sshLeft : (rightMode == .ssh ? nil : local)
    }
    guard let source, let (entry, kind) = preview.target(source) else {
      return nil
    }
    return (source, entry, kind)
  }

  private func drawInfo(_ screen: Screen, _ y: Int) {
    let c = clip
    let hidden = (active as? PathPane)?.showHidden ?? local.showHidden
    // キーの名前（[keyId]）・表示・説明。選んでいる窓で押しても何もしないキーは出さない。
    var keys: [(String, String, String)] = [
      ("char:h", "H", "Help"),
      ("char:l", "L", "reLoad"),
      ("char:s", "S", "Shell"),
      ("char:v", "V", "preView [\(preview.on ? "on" : "off")]"),
      ("char:z", "Z", "Zip"),
      ("char:u", "U", "Unzip"),
      ("char:.", ".", "Hidden [\(hidden ? "on" : "off")]"),
      ("char: ", "Space", tr("main_view.keys.mark")),
      ("tab", "Tab", tr("main_view.keys.tab")),
    ]
    if uses(.ssh) {
      keys.append(("backTab", "Shift+Tab", tr("main_view.keys.left_tab")))
    }
    keys.append(("left", "←→", tr("main_view.keys.switch_pane")))
    keys.append(("ctrl:l", "Ctrl+L", "Location"))
    keys.append(("char:o", "O", "clOse"))
    drawKeyHints(screen, y, keys.filter { canPress($0.0) }.map { ($0.1, $0.2) }, note: c.map {
      tr("main_view.clip.note", ["action": $0.move ? tr("main_view.clip.move") : tr("main_view.clip.copy"), "count": $0.length])
    })
  }

  private func drawFunctionKeyBar(_ screen: Screen, _ y: Int) {
    screen.fill(0, y, screen.width, 1, Style())
    // F12（G）は、選んでいる窓で G を押したときの転送。Google Drive は暗号化して転送、Git は Git コマンド、SSH は scp、
    // iCloud Drive・右のローカルはコピー。向き（左→右・右→左）は名前の矢印で見せる。
    // 選んでいる窓で使えないキーは、名前を出さずに空ける（キーの位置は変えない）。
    let keys = functionKeys.map { key in key.flatMap { canPress("char:\($0.1.lowercased())") ? $0 : nil } }
    drawFunctionKeys(screen, y, keys + [canPress("char:g") ? (transferCommand?.label ?? "", "G") : nil])
  }

  /// 選んでいる窓で、キー [id]（[keyId] の名前）を押して何かできるか。読むだけの場所での書き込む操作は、できないとする。
  private func canPress(_ id: String) -> Bool {
    let pane = active
    if !pane.allowsKey(id) {
      return false
    }
    if let operation = Self.operations[id] {
      guard let command = operation == .transfer ? transferCommand : pane.commands[operation] else {
        return false
      }
      // 切断（O）は、SSH でつないでいるときだけ。
      if operation == .signOut && (pane as? SshPane)?.ssh == nil {
        return false
      }
      return !(command.writes && pane.readOnly)
    }
    switch id {
    case "char:c", "char:m", "f2", "f3":
      return pane.canClip
    case "char: ":
      return pane.canMark
    default:
      return true
    }
  }

  /// 選んでいる窓で G・F12 を押したときに実行するコマンド。左の窓の G は右のタブが決め、右の窓の G は右のタブ自身が持つ。
  /// 左が SSH のときは、右がローカル（左の接続先との scp）・Git（Git コマンド）・SSH（左の接続先からつないだ接続先との scp）。
  private var transferCommand: Command? {
    if leftMode == .ssh && rightMode == .local {
      return rightActive ? RightLocalUpload() : LeftSshDownload()
    }
    if leftMode == .ssh && !showGit && rightMode != .ssh {
      return nil
    }
    if !rightActive {
      return right.transferCommand
    }
    let command = right.commands[.transfer]
    return command is RightTransfer ? right.transferCommand : command
  }

  // ---- キー ----

  func handleKey(_ key: Key) {
    if busy {
      return
    }
    let pane = active
    let id = Self.keyId(key)
    // 操作のキーは、選んでいるタブがその操作のコマンドを持っていれば実行する。
    if let operation = Self.operations[id] {
      // 左が SSH のときは、左の SSH の窓が持つ転送（左のローカルへのダウンロード）ではなく、右のタブで決まる転送にする。
      if operation == .transfer && leftMode == .ssh {
        if let command = transferCommand {
          run { await runCommand(command, self) }
        }
        return
      }
      if let command = pane.commands[operation] {
        run { await runCommand(command, self) }
      }
      return
    }
    // Esc は、C・M で選んでいればそれを取り消す（どのタブでも）。
    if key.name == "escape" {
      clip = nil
      return
    }
    if !pane.allowsKey(id) {
      return
    }
    let page = max(1, pane.visibleRows)
    switch key.name {
    case "up":
      pane.move(-1)
    case "down":
      pane.move(1)
    case "pageUp":
      pane.move(-page)
    case "pageDown":
      pane.move(page)
    case "home":
      pane.move(-pane.entries.count)
    case "end":
      pane.move(pane.entries.count)
    case "tab":
      // 右の窓を Google Drive → git（git があるとき）→ SSH → iCloud Drive → ローカルの順に切り替える。
      // 設定ファイルで off のタブと、左が SSH のときに使えないタブは飛ばす。
      let modes = rightModes
      if modes.isEmpty {
        return
      }
      rightChosen = true
      if let index = modes.firstIndex(of: rightMode) {
        rightMode = modes[(index + 1) % modes.count]
      } else {
        rightMode = modes[0]
      }
      if showGit {
        Task { await showGitPane() }
      }
      app.requestRender()
    case "backTab":
      switchLeft()
    case "left":
      rightActive = false
    case "right":
      rightActive = true
    case "backspace":
      run { await pane.up() }
    case "f2":
      setClip(move: false)
    case "f3":
      setClip(move: true)
    case "char":
      handleChar(key)
    default:
      break
    }
  }

  private func handleChar(_ key: Key) {
    let pane = active
    switch key.char!.lowercased() {
    // 日本語入力がオンのままだと、Space は全角スペースで届く。
    case " ", "　":
      pane.toggleMark()
      clearOtherMarks(pane)
    case "*":
      pane.invertMarks()
      clearOtherMarks(pane)
    case "c":
      setClip(move: false)
    case "m":
      setClip(move: true)
    case "v":
      preview.on.toggle()
    case "?", "h":
      run { await self.help() }
    default:
      break
    }
  }

  /// キーの名前。文字は「char:小文字」、Ctrl は「ctrl:文字」。[Pane.allowsKey] と [operations] で使う。
  private static func keyId(_ key: Key) -> String {
    switch key.name {
    case "char": "char:\(key.char!.lowercased())"
    case "ctrl": "ctrl:\(key.ctrl!)"
    default: key.name
    }
  }

  /// 操作のキー。どのタブでも同じキーは同じ操作で、操作の中身はタブ（[Pane.commands]）が決める。
  private static let operations: [String: Operation] = [
    "enter": .enter,
    "delete": .delete,
    "f1": .chmod,
    "f4": .delete,
    "f5": .touch,
    "f6": .mkdir,
    "f7": .rename,
    "f8": .edit,
    "f12": .transfer,
    "ctrl:l": .goToPath,
    "char:p": .paste,
    "char:a": .chmod,
    "char:s": .shell,
    "char:e": .edit,
    "char:d": .delete,
    "char:r": .rename,
    "char:k": .mkdir,
    "char:t": .touch,
    "char:z": .compress,
    "char:u": .extract,
    "char:o": .signOut,
    "char:l": .reload,
    "char:~": .goHome,
    "char:.": .toggleHidden,
    "char:g": .transfer,
  ]

  /// 非同期の操作を1つずつ実行する。終わったら、git の窓を出していれば読み直す（フォルダーの移動やファイルの操作に合わせる）。
  /// 読み直しは待たずに、次のキーを受け付ける。
  private func run(_ action: @escaping () async -> Void) {
    busy = true
    Task {
      await action()
      busy = false
      if showGit {
        Task { await showGitPane() }
      }
      syncRightSsh()
      app.requestRender()
    }
  }

  /// 右の SSH のつなぐ元を、左に合わせる。左が SSH ならその接続先から（つないでいなければ待つ）、ローカルならこの Mac から。
  /// 変わったときは、右の SSH の接続を切る。
  private func syncRightSsh() {
    if !uses(.ssh) {
      return
    }
    let via = leftMode == .ssh ? sshLeft.ssh : nil
    Task { await ssh.follow(via, waiting: leftMode == .ssh && via == nil) }
  }

  /// 左の窓をローカルと SSH で切り替える（Shift+Tab）。SSH のタブが off なら何もしない。
  /// 右に左が SSH のときに使えないタブを出していれば、右をローカル（off なら使えるうち最初のタブ）にする。
  private func switchLeft() {
    if !uses(.ssh) {
      return
    }
    leftMode = leftMode == .local ? .ssh : .local
    if leftMode == .ssh && sshLeft.entries.isEmpty && !sshLeft.loading {
      Task { await sshLeft.load() }
    }
    let modes = rightModes
    if !modes.contains(rightMode) && !modes.isEmpty {
      rightMode = modes.contains(.local) ? .local : modes[0]
    }
    if showGit {
      Task { await showGitPane() }
    }
    syncRightSsh()
    app.requestRender()
  }

  // ---- 操作 ----

  /// マークできるのは片方の窓だけ。[pane] にマークがあれば、ほかの窓のマークを外す。
  private func clearOtherMarks(_ pane: Pane) {
    if pane.marks.isEmpty {
      return
    }
    for other in panes where other !== pane {
      other.marks.clear()
    }
  }

  /// 対象（マークした項目、なければカーソルの項目）を、P で貼り付ける対象にする（C・M）。
  /// 次のキーを待たせないよう、ほかのコマンドと違ってその場で済ませる。
  private func setClip(move: Bool) {
    let pane = active
    if pane.readOnly {
      run { _ = await pane.checkWritable() }
      return
    }
    let targets = pane.targetsFor()
    if !pane.ready || targets.isEmpty {
      return
    }
    guard let next = pane.makeClip(targets, move: move) else {
      return
    }
    clip = next
    pane.marks.clear()
  }

  func reloadAll() async {
    async let leftLoaded: Void = left.load()
    async let driveLoaded: Void = drive.load()
    _ = await (leftLoaded, driveLoaded)
  }

  private func help() async {
    await app.showMessage(tr("main_view.help.title"), Self.helpText, maxWidth: 82)
  }

  private static var helpText: String { tr("main_view.help.text") }

  /// 終了している途中。
  private var quitting = false

  /// 確認せずに終了する（⌘Q・窓を閉じる・メニューや Dock の終了）。操作の途中や、ダイアログを開いていても終了する。
  func quit() async {
    if quitting {
      return
    }
    quitting = true
    // 終了の前に、起動時に起動した Google ドライブ for デスクトップを止め、SSH の接続を片付ける。
    await drive.stopDriveApp()
    // 右の SSH は左の SSH を経由していることがあるので、右から片付ける。
    await ssh.dispose()
    await sshLeft.dispose()
    app.quit()
  }
}
