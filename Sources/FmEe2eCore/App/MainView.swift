/// FD風の2画面。左はローカル・SSH の接続先（Shift+Tab で切り替える）、
/// 右は Google Drive・git status・SSH の接続先・iCloud Drive・ローカル（Tab で切り替える）。
/// 右の窓に出すタブは設定ファイル（[AppConfig]）で選び、off のタブは使わない（確かめもしない）。
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
    noTab = NoTabPane(app, ["右の窓に出すタブがありません。", "~/.config/fm-ee2e/config.yml の right_tabs で on にしてください。"])
    gitChecking = NoTabPane(app, ["確認中…"])
    rightMode = Self.startMode(config)
    preview = PreviewOverlay(app)
    // 左の SSH を切る（別の接続先につなぎ直すときを含む）前に、それを経由する右の SSH を切る。
    sshLeft.beforeDisconnect = { [unowned self] connection in
      if ssh.ssh?.via === connection {
        await ssh.follow(nil, waiting: leftMode == .ssh)
      }
    }
    Task { await local.load() }
    let driveChecked = Task { if uses(.drive) { await drive.check() } }
    if uses(.ssh) { Task { await ssh.load() } }
    if uses(.icloud) { Task { await icloud.check() } }
    if uses(.local) { Task { await localRight.load() } }
    let gitFound = Task {
      if uses(.git) {
        let found = (try? await Git.locate()) ?? nil
        gitLocated = true
        if let found {
          gitPane = GitPane(app, found)
        }
        app.requestRender()
      }
    }
    Task { await chooseStartRight(driveChecked, gitFound) }
  }

  /// 設定ファイルの内容。
  let config: AppConfig

  /// 右の窓に [mode] のタブを出すか（設定ファイルで on か）。
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
    case (.ssh, nil): await gitPane!.showNotice(["左の SSH で接続先を選んでください。"])
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
      screen.text(0, 0, "端末が小さすぎます", Style(fg: Palette.error))
      return
    }
    // 上は枠で囲んだ4行（タイトル入りの線、容量、所有者、下の線）。
    drawHeader(screen)
    drawUsage(screen, 1, active)
    drawOwnership(screen, 2, active)
    let leftWidth = w / 2
    // 下から、ファンクションキー、空白、案内、マークの4行。
    let paneHeight = h - 8
    left.draw(screen, 0, 4, leftWidth, paneHeight, focused: !rightActive, accentBorder: !rightActive)
    // 右の窓（Google Drive・git・SSH・iCloud Drive）は、選んでいなくても色で見分けられるよう、いつも自分の色の枠にする。
    right.draw(screen, leftWidth, 4, w - leftWidth, paneHeight, focused: rightActive, accentBorder: true)
    if let (source, entry, kind) = previewTarget() {
      // 選んでいる窓と反対側に重ねる。
      if !rightActive {
        preview.draw(screen, source, entry, kind, leftWidth, 4, w - leftWidth, paneHeight)
      } else {
        preview.draw(screen, source, entry, kind, 0, 4, leftWidth, paneHeight)
      }
    }
    if let marked = panes.first(where: { !$0.marks.isEmpty }) {
      drawMarks(screen, h - 4, marked, marked === local || marked === sshLeft ? "左" : "右")
    }
    drawInfo(screen, h - 3)
    drawFunctionKeyBar(screen, h - 1)
  }

  /// 選んでいるローカルの窓（左のローカルか、右のローカル・iCloud Drive のタブ）でカーソルが画像か動画に乗っていて、
  /// プレビューを反対側の窓に重ねられるとき、その窓と項目と種類。左で選んでいて右が SSH のときは重ねない。
  private func previewTarget() -> (LocalPane, Entry, PreviewKind)? {
    let source: LocalPane?
    if rightActive {
      switch rightMode {
      case .local: source = localRight
      case .icloud: source = icloud
      default: source = nil
      }
    } else {
      source = rightMode == .ssh || leftMode == .ssh ? nil : local
    }
    guard let source, let (entry, kind) = preview.target(source) else {
      return nil
    }
    return (source, entry, kind)
  }

  private func drawInfo(_ screen: Screen, _ y: Int) {
    let c = clip
    let hidden = (active as? PathPane)?.showHidden ?? local.showHidden
    var keys: [(String, String)] = [
      ("H", "Help"),
      ("L", "reLoad"),
      ("S", "Shell"),
      ("V", "preView [\(preview.mode.label)]"),
      ("Z", "Zip"),
      ("U", "Unzip"),
      (".", "Hidden [\(hidden ? "on" : "off")]"),
      ("Space", "マーク"),
      ("Tab", "タブ切替"),
    ]
    if uses(.ssh) {
      keys.append(("Shift+Tab", "左タブ切替"))
    }
    keys.append(("←→", "タブ移動"))
    keys.append(("Ctrl+L", "Location"))
    if (rightMode == .ssh && ssh.ssh != nil) || (leftMode == .ssh && sshLeft.ssh != nil) {
      keys.append(("O", "clOse"))
    }
    keys.append(("Esc/Q", "Quit"))
    drawKeyHints(screen, y, keys, note: c.map { "\($0.move ? "移動" : "コピー") \($0.length)項目  P 貼り付け  Esc 取り消し" })
  }

  private func drawFunctionKeyBar(_ screen: Screen, _ y: Int) {
    screen.fill(0, y, screen.width, 1, Style())
    // F12（G）は、選んでいる窓で G を押したときの転送。Google Drive は暗号化して転送、Git は Git コマンド、SSH は scp、
    // iCloud Drive・右のローカルはコピー。向き（左→右・右→左）は名前の矢印で見せる。
    drawFunctionKeys(screen, y, (transferCommand?.label ?? "", "G"))
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
    // Esc は、C・M で選んでいればそれを取り消し、選んでいなければ Q と同じく終了を確かめる（どのタブでも）。
    if key.name == "escape" {
      if clip != nil {
        clip = nil
      } else {
        run { await self.quit() }
      }
      return
    }
    if !pane.allowsKey(id) {
      return
    }
    let page = max(1, app.terminal.height - 11)
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
      preview.cycleMode()
    case "?", "h":
      run { await self.help() }
    case "q":
      run { await self.quit() }
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
    await app.showMessage("キー操作", Self.helpText, maxWidth: 82)
  }

  private static let helpText = """
    ↑↓ PgUp PgDn Home End  カーソル移動

    ← →            左右の窓を切り替え
    Tab            右の窓を Google Drive / git status / SSH / iCloud Drive / ローカル に切り替え
                   (SSH はつなぐ前は ~/.ssh/config の Host の一覧。Enter でつなぐ)
    Shift+Tab      左の窓をローカル / SSH に切り替え
                   (左が SSH のときの右の SSH は、左の接続先から、その ~/.ssh/config でつなぐ)
                   (左が SSH のときは、右はローカル / git status / SSH だけ。
                    git status は接続先のリポジトリ。右がローカルなら G は SCP 転送)
    SSH            接続先のファイルを一覧・マーク・コピー・移動・削除
                   G/F12: ローカルとの転送  E/F8: 接続先で編集
                   S: 接続先でコマンドを実行
    Enter          フォルダーなら移動
                   .zip .tar.gz .tar.xz は中をフォルダーのように表示 (読むだけ)
                   Driveのファイルは一時フォルダーに復号
                   SSH のファイルは接続先の $EDITOR (未設定・空ならvim) で編集
                   (SSH の圧縮ファイルは、接続先の tar・bsdtar・unzip で中を表示)
                   実行ファイルは引数を入れて実行
                   割り当てのあるファイルはopen
                   割り当てのないファイルはエディタ
    BS             親フォルダーへ
    Space          マーク / 反転
    *              開いているフォルダーのマークを全部反転
    C / M          コピー / 移動
    P              開いているフォルダーに貼り付け
    G              転送 (左→右: アップロード、右→左: ダウンロード)
                   (右が SSH のときは F12 と同じく SCP 転送、同名は小窓で確認。
                    左も SSH なら、左の接続先で scp を実行して左右の接続先の間で送る)
                   (右が iCloud Drive・ローカルのときはコピー。同名は小窓で確認)
                   (右が git status のときは Git コマンド。左で押すと左のファイルに
                    git add / restore / rm を、ファイルの状態に合わせて出す)
                   カーソルとマークの候補が複数ならマークだけ、1件ならカーソル
    D / Del        削除 (ゴミ箱へ移動。SSH は rm で削除)
    A              権限変更
    S              シェル (コマンドを入れて枠の中で実行。終わったら Enter で戻る)
    E              エディタ ($EDITORがなければvim固定)
    R              名前の変更
    K              mkdir (空のフォルダーを作る)
    T              touch (空のファイルを作る)
    Z              圧縮 (zip / tar.gz / tar.xz をカレントに作る。
                   SSH は接続先の zip・tar・gzip・xz で作れる形式だけ)
    U              カーソルの .zip .tar.gz .tar.xz をカレントに展開
                   (SSH は接続先の tar・bsdtar・unzip で。なければ展開できない)
    Ctrl+L         ディレクトリへ移動
    ~              ホームへ移動
    .              隠しファイルを表示
    V              画像・動画のプレビューを右の窓に出す (off → dmp → iTerm → off)
    O              SSH は切断
    L              再読み込み
    H / ?          このヘルプを表示
    Q / Esc        終了 (C・M で選んでいるときの Esc は取り消し)
    """

  /// Ctrl+C など、キー以外からの終了要求。
  func requestQuit() {
    if let interrupt = app.interrupt {
      // 枠の中で動かしているプログラムに届ける。
      interrupt()
    } else if !busy {
      run { await self.quit() }
    }
  }

  private func quit() async {
    let message = "Quit? (Yes: Enter / No: ESC)"
    if !(await app.confirm("終了", message, maxWidth: textWidth(message) + 4, showHints: false)) {
      return
    }
    // 終了の前に、起動時に起動した Google ドライブ for デスクトップを止め、SSH の接続を片付ける。
    await drive.stopDriveApp()
    // 右の SSH は左の SSH を経由していることがあるので、右から片付ける。
    await ssh.dispose()
    await sshLeft.dispose()
    app.quit()
  }
}
