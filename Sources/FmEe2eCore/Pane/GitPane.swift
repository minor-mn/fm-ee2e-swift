/// 右の窓に Google Drive の代わりに出す git status（見るだけ）。左で開いているフォルダーのリポジトリを見る。
/// 左がローカルならこの Mac の git、SSH なら接続先の git を使う。
final class GitPane: Pane {
  init(_ app: App, _ localGit: Git) {
    self.localGit = localGit
    super.init(app)
  }

  /// この Mac の git。
  let localGit: Git

  /// 見ているリポジトリの git。読み込む前と、接続先に git がないときは nil。
  private var currentGit: Git?

  /// 見ているリポジトリの git（[ready] のときだけ使う）。
  var git: Git { currentGit ?? localGit }

  /// 左の SSH の接続。左がローカルなら nil。
  private(set) var ssh: Ssh?

  /// 見るフォルダー（左で開いているフォルダー）。
  var dir: String?

  /// リポジトリの一番上のフォルダー。リポジトリの外なら nil。
  var root: String?
  private var message: [String]?

  /// 一覧の代わりに出す案内（左の SSH がつながっていないときなど）。
  private var notice: [String]?

  override var title: String { loading && !entries.isEmpty ? tr("git_pane.loading") : "Git" }

  /// 操作のたびに読み直すので、ちらつかないよう前の一覧を出したまま読み直す（別のフォルダーに移ったときは消す）。
  override var keepsEntriesWhileLoading: Bool { true }

  override var location: String {
    guard let path = root ?? dir else {
      return ""
    }
    if let remote = ssh {
      return "\(remote.host):\(path)"
    }
    return path
  }

  override var accent: Rgb { colors.accent ?? colors.orange }

  override var selection: Rgb { colors.selection ?? colors.orangeDark }

  override var themeKey: ThemeKey { .git }

  override var placeholder: [String]? { message }

  /// 上の帯に出す、リポジトリ名とユーザー。
  private var repositoryText: String?

  override var headerText: String? { repositoryText ?? "" }

  override func fetch() async throws -> [Entry] {
    if let notice {
      root = nil
      repositoryText = nil
      message = notice
      return []
    }
    guard let current = dir else {
      return []
    }
    let remote = ssh
    // 待っている間に別のフォルダー・接続先へ移っていたら、前の結果で上書きしない（この一覧も捨てられる）。
    func moved() -> Bool { dir != current || ssh !== remote }
    var git = currentGit
    if git == nil {
      if let remote {
        git = try await Git.overSsh(remote)
      } else {
        git = localGit
      }
      if moved() {
        return []
      }
      if git == nil {
        root = nil
        repositoryText = nil
        message = [tr("git_pane.no_git")]
        return []
      }
      currentGit = git
    }
    let found = try await git!.statusAt(current)
    if moved() {
      return []
    }
    root = found?.0
    repositoryText = found.flatMap { gitRepositoryText($0.1) }
    guard let found else {
      message = [tr("git_pane.not_repository")]
      return []
    }
    message = nil
    // ブランチ名とブロックの行を、1行ずつ項目にする。
    return gitStatusLines(found.1).map { Entry(name: $0.text, isDir: false, data: $0) }
  }

  override var commands: [Operation: Command] {
    notice != nil
      ? [:]
      : [
        .enter: GitEnter(),
        .reload: ReloadCommand(),
        .edit: GitEdit(),
        // シェルは、左がローカルなら左のフォルダーで、SSH なら接続先の左のフォルダーで実行する。
        .shell: ssh == nil ? LocalShell() : GitSshShell(),
        .transfer: RightTransfer(),
      ]
  }

  override var transferCommand: Command? { notice != nil ? nil : GitCommand() }

  private static let blockedKeys: Set<String> = ["backspace", "f2", "f3", "char:c", "char:m"]

  /// ファイルを操作するキー・クリップボードは使わない。
  override func allowsKey(_ id: String) -> Bool { !Self.blockedKeys.contains(id) }

  /// 今のブランチ名（ブランチにいなければ「(no branch)」）。読み込む前は nil。
  var branch: String? { lineText(.branch) }

  /// 今のブランチの紐付け先のリモート（紐付いていなければ「(no upstream)」など）。
  var remote: String? { lineText(.remote) }

  /// push 先だけを別にするリモート（branch.<名前>.pushRemote）。
  var pushRemote: String? { lineText(.pushRemote) }

  /// コミットしていない変更（untracked を含む）があるか。
  var hasChanges: Bool { entries.contains { ($0.data as? GitStatusLine)?.kind == .file } }

  /// staged のファイルがあるか。
  var hasStaged: Bool { entries.contains { ($0.data as? GitStatusLine)?.section == "staged" } }

  /// [kind] の行の文。なければ nil。
  private func lineText(_ kind: GitLineKind) -> String? {
    entries.lazy.compactMap { $0.data as? GitStatusLine }.first { $0.kind == kind }?.text
  }

  override func selectable(_ entry: Entry) -> Bool { (entry.data as? GitStatusLine)?.selectable ?? true }

  override func markable(_ entry: Entry) -> Bool { (entry.data as? GitStatusLine)?.kind == .file }

  /// 同じファイルが staged と not staged の両方に出るので、ブロックごとに見分ける。
  override func keyOf(_ entry: Entry) -> String {
    if let line = entry.data as? GitStatusLine {
      return "\(folderKey)/\(line.section)/\(line.text)"
    }
    return super.keyOf(entry)
  }

  /// この Mac の [folder] のリポジトリを読み直す。
  func show(_ folder: String) async { await show(nil, folder) }

  /// 接続先 [ssh] の [folder] のリポジトリを読み直す。
  func showRemote(_ ssh: Ssh, _ folder: String) async { await show(ssh, folder) }

  /// 一覧の代わりに [notice] を出す。
  func showNotice(_ notice: [String]) async {
    if self.notice == nil {
      marks.clear()
      resetCursor()
    }
    self.notice = notice
    await load()
  }

  private func show(_ ssh: Ssh?, _ folder: String) async {
    // 別の接続先（ローカルを含む）に移ったら、git を探し直し、前の場所のマークを外す（同じパスでも別のリポジトリ）。
    if ssh !== self.ssh || notice != nil {
      self.ssh = ssh
      currentGit = ssh == nil ? localGit : nil
      notice = nil
      marks.clear()
      dir = nil
    }
    if folder != dir {
      // 前のフォルダーの一覧は、読み込み中も出さない。
      dir = folder
      entries = []
      resetCursor()
    }
    await load()
  }

  override var canGoUp: Bool { false }

  override var folderKey: String { root ?? "" }

  /// サイズや日時の欄を使わず1行の文として書く。リポジトリ名などの見出しとブランチ名は太字。
  override func drawRow(_ screen: Screen, _ entry: Entry, _ x: Int, _ y: Int, _ width: Int, _ style: Style, marked: Bool) {
    guard let line = entry.data as? GitStatusLine else {
      super.drawRow(screen, entry, x, y, width, style, marked: marked)
      return
    }
    switch line.kind {
    // push 先・リモート名・ブランチ名は、リポジトリ名の見出しの下に、ファイルと同じく字下げして出す。
    case .pushRemote, .remote:
      screen.text(x + 2, y, truncate(line.text, width - 3), style.copyWith(fg: accent))
    case .branch:
      screen.text(x + 2, y, truncate(line.text, width - 3), style.copyWith(fg: accent, bold: true))
    case .repository:
      screen.text(x, y, truncate(line.text, width - 1), style.copyWith(fg: Palette.muted, bold: true))
    case .heading:
      // ブロックの見出しは、設定ファイルの sections で決めた色・太字・下線（なければ補足の文字の色の太字）。
      let key = line.text.replacingOccurrences(of: " ", with: "_")
      let colors = Theme.active.colors
      screen.text(
        x, y, truncate(line.text, width - 1),
        style.copyWith(
          fg: colors.gitSectionColor[key] ?? Palette.muted,
          bold: colors.gitSectionBold[key] ?? true,
          underline: colors.gitSectionUnderline[key] ?? false
        )
      )
    case .note:
      screen.text(x + 2, y, truncate(line.text, width - 3), style.copyWith(fg: Palette.muted))
    case .file:
      // ほかの窓と同じく、マーク・名前・変更の種類（サイズの欄）の順に出す。
      let nameWidth = width - 2 - 1 - 9 - 1
      screen.text(x, y, marked ? "*" : " ", style.copyWith(fg: Palette.marked, bold: true))
      screen.text(x + 2, y, truncate(line.text, nameWidth), style.copyWith(fg: marked ? Palette.marked : accent, bold: marked))
      // 変更の種類は、設定ファイルの status で決めた色（なければ補足の文字の色）。
      let labelColor = Theme.active.colors.gitStatus[line.statusKey] ?? Palette.muted
      screen.text(x + 2 + nameWidth + 1, y, padLeft(line.label, 9), style.copyWith(fg: labelColor))
    }
  }
}
