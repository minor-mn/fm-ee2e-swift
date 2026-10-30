import Foundation

/// 右の Git のタブの転送（G・F12）。Git コマンドを選んで実行する。git status の読み直しは、実行が終わったあとに呼ぶ側が行う。
final class GitCommand: Command {
  override var label: String { "Git" }

  /// 左の窓を選んでいても、Git の窓で実行する。
  override func paneIn(_ workspace: Workspace) -> Pane? { workspace.gitPane }

  /// Git の窓を選んでいれば Git の窓の対象に、左の窓を選んでいれば左の対象に実行する。
  override func run(_ c: CommandContext) async {
    let pane = c.pane as! GitPane
    let git = GitActions(c)
    do {
      if c.workspace.active === pane {
        try await git.command(pane)
      } else {
        try await git.leftCommand(pane, c.workspace.left)
      }
    } catch {
      await c.app.showError(error)
    }
  }
}

/// Git のタブで Enter。カーソルの行がリモート・push 先・ブランチならそれを選び、ファイルならその差分を出す。
final class GitEnter: EnterCommand {
  override func run(_ c: CommandContext) async {
    let pane = c.pane as! GitPane
    if pane.loading {
      return
    }
    let git = GitActions(c)
    let line = c.targets.first?.entry.data as? GitStatusLine
    do {
      if let line, line.kind == .remote {
        try await git.chooseRemote(pane)
      } else if let line, line.kind == .pushRemote {
        try await git.choosePushRemote(pane)
      } else if let line, line.kind == .branch {
        try await git.chooseBranch(pane)
      } else {
        try await git.gitDiff(pane)
      }
    } catch {
      await c.app.showError(error)
    }
  }
}

/// 重なりを除いた、最初に出てきた順の並び（Dart の Set リテラルと同じ）。
private func distinct(_ items: [String]) -> [String] {
  var seen = Set<String>()
  return items.filter { seen.insert($0).inserted }
}

/// Git の窓での操作。
private final class GitActions {
  init(_ c: CommandContext) {
    self.c = c
  }

  let c: CommandContext

  var app: App { c.app }

  /// ブランチの切り替えなどで作業ツリーのファイルが変わったときに、左の窓（ローカルか SSH）を読み直す。
  func onFilesChanged() async { await c.workspace.left.load() }

  /// 選択の小窓の1行。今のもの（[current]）は先頭に「* 」、ほかは空白2つを付けて揃える。
  private static func currentMark(_ option: String, _ current: String?) -> String {
    "\(option == current ? "*" : " ") \(option)"
  }

  /// 登録されているリモートの一覧から選び、今のブランチの紐付け先にする。(no upstream) を選ぶと紐付けを外す。
  func chooseRemote(_ pane: GitPane) async throws {
    let current = pane.remote
    guard let root = pane.root, let branch = pane.branch, pane.ready else {
      return
    }
    if branch == "(no branch)" {
      app.showStatus(tr("git_commands.remote.no_branch"))
      return
    }
    let remotes = try await pane.git.remotes(root)
    if remotes.isEmpty {
      app.showStatus(tr("git_commands.remote.none_registered"))
      return
    }
    let none = "(no upstream)"
    let options = remotes + [none]
    guard let choice = await app.askChoice(
      tr("git_commands.remote.title", ["branch": branch]), options.map { GitActions.currentMark($0, current) }
    ), options[choice] != current else {
      return
    }
    if options[choice] == none {
      try await pane.git.unsetBranchRemote(root, branch)
    } else {
      try await pane.git.setBranchRemote(root, branch, options[choice])
    }
    // git status の読み直しは、_run が終わったときに行う。
  }

  /// ブランチの一覧から選んで切り替える。紐付け先のリモートがあれば、先に git fetch して、リモートにだけあるブランチも並べる。
  /// 一番上の「新しいブランチを作る」で、名前を聞いて今の場所から作って切り替える。
  func chooseBranch(_ pane: GitPane) async throws {
    guard let root = pane.root, pane.ready else {
      return
    }
    let current = pane.branch
    let remote = pane.remote
    let git = pane.git
    var fetched = false
    if let remote, !remote.hasPrefix("(") {
      // push と同じく枠の中の端末で動かす（認証を聞かれても答えられる）。うまくいけばすぐ戻り、失敗したときだけ Enter を待つ。
      // 失敗したら、手元のブランチだけを出す。
      let (program, args) = try git.commandLine(["-C", root, "fetch", remote], tty: true)
      let code = await runInTerminal(
        app,
        "\(git.placeOf(root)) $ git fetch \(remote)",
        program,
        args,
        waitAfterExit: { code in code != 0 }
      )
      fetched = code == 0
    }
    let branches = try await git.localBranches(root)
    // リモートにだけあるブランチ（手元に同じ名前がないもの）。
    var remoteOnly: [String] = []
    if fetched {
      for name in try await git.remoteBranches(root, remote!)
      where !branches.contains(String(name.dropFirst(remote!.count + 1))) {
        remoteOnly.append(name)
      }
    }
    let create = tr("git_commands.branch.create")
    // 先頭に「新しいブランチを作る」。そのあとと、手元のブランチとリモートにだけあるブランチの間は、空行で区切る（空文字は選べない区切り）。
    let options = [create, ""] + branches + (remoteOnly.isEmpty ? [] : [""]) + remoteOnly
    guard let choice = await app.askChoice(
      tr("git_commands.branch.switch_title"), options.map { $0.isEmpty ? "" : GitActions.currentMark($0, current) }
    ), options[choice] != current else {
      return
    }
    let chosen = options[choice]
    if chosen == create {
      try await createBranch(pane, root, create)
      return
    }
    // コミットしていない変更（untracked を含む）は切り替え先に持っていく。切り替え先と重なると git が止める（変更は消えない）。
    if pane.hasChanges,
      !(await app.confirm(
        tr("git_commands.branch.switch_title"),
        tr("git_commands.branch.switch_with_changes"),
        yes: tr("git_commands.branch.switch_yes")
      ))
    {
      return
    }
    try await app.withProgress(tr("git_commands.running", ["command": "git switch"])) {
      if remoteOnly.contains(chosen) {
        // origin/xxx は、同じ名前の手元のブランチを作って紐付ける。
        try await git.switchBranch(root, String(chosen.dropFirst(remote!.count + 1)), track: chosen)
      } else {
        try await git.switchBranch(root, chosen)
      }
    }
    // 切り替えでファイルが変わるので、左の窓も読み直す（Git の窓は _run が終わったときに読み直す）。
    await onFilesChanged()
  }

  /// 新しいブランチの名前を聞いて、今の場所から作って切り替える（git switch -c）。
  /// コミットしていない変更は、そのまま新しいブランチに持っていく。
  func createBranch(_ pane: GitPane, _ root: String, _ title: String) async throws {
    let name = (await app.input(
      title,
      message: tr("git_commands.branch.new_name"),
      validate: { value in value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? tr("git_commands.branch.name_required") : nil }
    ))?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let name, !name.isEmpty else {
      return
    }
    if !(try await pane.git.isValidBranchName(root, name)) {
      await app.showError(tr("git_commands.branch.invalid_name", ["name": name]))
      return
    }
    try await app.withProgress(tr("git_commands.running", ["command": "git switch"])) { try await pane.git.switchBranch(root, name, create: true) }
    // git status の読み直しは、_run が終わったときに行う。
  }

  /// push 先だけを別にするリモート（branch.<名前>.pushRemote）を、登録されているリモートから選ぶか、設定を消す。
  func choosePushRemote(_ pane: GitPane) async throws {
    guard let root = pane.root, let branch = pane.branch, pane.ready else {
      return
    }
    if branch == "(no branch)" {
      app.showStatus(tr("git_commands.push_remote.no_branch"))
      return
    }
    let current = pane.pushRemote
    let remotes = try await pane.git.remotes(root)
    let none = "<no branch.pushRemote>"
    let options = remotes + [none]
    guard let choice = await app.askChoice(
      tr("git_commands.push_remote.title", ["branch": branch]),
      options.map { GitActions.currentMark($0, current) },
      note: tr("git_commands.push_remote.note")
    ), options[choice] != current else {
      return
    }
    try await pane.git.setBranchPushRemote(root, branch, options[choice] == none ? nil : options[choice])
    // git status の読み直しは、_run が終わったときに行う。
  }

  /// 対象のファイル（Enter ではカーソルのファイル）の差分を、画面全体に出す。
  /// staged のファイルは add した変更、not staged のファイルは add していない変更、untracked のファイルは全行を追加として出す。unmerged は対象外。
  func gitDiff(_ pane: GitPane) async throws {
    guard let root = pane.root, pane.ready else {
      return
    }
    let lines: [GitStatusLine] = c.targets.compactMap { mark in
      guard let line = mark.entry.data as? GitStatusLine,
        line.kind == .file && mark.parent == pane.folderKey && line.section != "unmerged"
      else {
        return nil
      }
      return line
    }
    if lines.isEmpty {
      // ブランチ名の行などでは何もしない。
      return
    }
    let pages = try await app.withProgress(tr("git_commands.running", ["command": "git diff"])) { () async throws -> [DiffPage] in
      var pages: [DiffPage] = []
      // staged・not staged・untracked の順にページにする。untracked は、全行を追加した差分として出す。
      for section in ["staged", "not staged", "untracked"] {
        let paths = distinct(lines.filter { $0.section == section }.flatMap { $0.paths })
        if paths.isEmpty {
          continue
        }
        let files =
          section == "untracked"
          ? try await pane.git.diffUntracked(root, paths)
          : try await pane.git.diff(root, paths, staged: section == "staged")
        pages.append(contentsOf: files.map { (file: $0, section: section) })
      }
      return pages
    }
    if pages.isEmpty {
      app.showStatus(tr("git_commands.no_diff"))
      return
    }
    await app.showModal { (close: @escaping (()) -> Void) in DiffView(pages, close) }
  }

  /// Git コマンドを選んで実行する。ファイルを対象にするコマンドは、マークしたファイル（なければカーソルのファイル）に実行する。
  func command(_ pane: GitPane) async throws {
    guard let root = pane.root, pane.ready else {
      return
    }
    // 選択した行。マークがあればマークした行、なければカーソルの行（カーソルの行を1つマークしたのと同じ扱い）。
    // ほかのリポジトリでマークしたものは含めない。
    let selected: [GitStatusLine] = c.targets.compactMap { mark in
      guard let line = mark.entry.data as? GitStatusLine, mark.parent == pane.folderKey else {
        return nil
      }
      return line
    }
    // 選択がファイルなら add（全部 staged なら add の取り消し）、ブランチ名の行なら push 系。
    let lines = selected.filter { $0.kind == .file }
    let onBranch = selected.count == 1 && selected[0].kind == .branch
    let allStaged = !lines.isEmpty && lines.allSatisfy { $0.section == "staged" }
    // ファイルの履歴は、コミットしたことのあるファイル1つだけ（untracked は対象外）。
    let onFile = selected.count == 1 && lines.count == 1 && lines[0].section != "untracked"
    // git commit は、staged のファイルが1つ以上あれば、選択にかかわらず出す（コミットするのは staged の全部）。
    var commands: [String] = []
    if !lines.isEmpty {
      commands.append(allStaged ? "git restore --staged" : "git add")
    }
    // コミットするのは staged の全部なので、マークがあるときはそれを添える。
    if pane.hasStaged {
      commands.append(pane.marks.isEmpty ? "git commit" : "git commit" + tr("git_commands.commit.marks_ignored"))
    }
    if onFile {
      commands.append("git log")
    }
    if onBranch {
      commands += ["git log", "git push", "git push --force-with-lease", "git switch -c"]
    }
    // pull とブランチのリネームは、ブランチにいるときだけ（一番下）。
    if onBranch && selected[0].text != "(no branch)" {
      commands += ["git pull", "git branch -m"]
    }
    // 変更を捨てる git restore は、選択が staged・not staged のファイルだけのとき（一番下）。
    if !lines.isEmpty && lines.allSatisfy({ $0.section == "staged" || $0.section == "not staged" }) {
      commands.append("git restore")
    }
    if commands.isEmpty {
      return
    }
    // G・F12 で開いたので、もう一度 G・F12 を押すと閉じる。端で ↑↓ を押しても閉じる。
    guard let choice = await app.askChoice(
      "Git",
      commands,
      closeKey: { key in key.name == "f12" || key.isLetter("g") },
      closeAtEdges: true
    ) else {
      return
    }
    let command = commands[choice]
    if command.hasPrefix("git commit") {
      let message = await app.input(
        "git commit",
        message: tr("git_commands.commit.message"),
        allowNewlines: true,
        validate: { value in
          value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? tr("git_commands.commit.message_required") : nil
        }
      )
      guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return
      }
      try await app.withProgress(tr("git_commands.running", ["command": "git commit"])) {
        try await pane.git.commit(root, message.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      pane.marks.clear()
      // git status の読み直しは、_run が終わったときに行う。
      return
    }
    if command == "git log" && onFile {
      // add した名前の変更は、新しい名前ではまだコミットがないので、元の名前でたどる。
      let line = lines[0]
      try await fileLog(pane.git, root, root, line.from ?? line.path)
      return
    }
    if command == "git log" {
      let branch = selected[0].text
      let commits = try await app.withProgress(tr("git_commands.running", ["command": "git log"])) { try await pane.git.log(root) }
      await app.showModal { (close: @escaping (()) -> Void) in LogView(app, close, pane.git, root, branch, commits) }
      return
    }
    if command == "git switch -c" {
      try await createBranch(pane, root, command)
      return
    }
    if command == "git branch -m" {
      try await renameBranch(pane, root, selected[0].text)
      return
    }
    if command.hasPrefix("git push") || command == "git pull" {
      // ブランチがリモートに紐付いていなければ（(no upstream)・(no remote)）、push・pull しない。
      let remote = pane.remote
      if remote == nil || remote!.hasPrefix("(") {
        await app.showMessage(command, tr("git_commands.push.no_remote"))
        return
      }
    }
    if command == "git pull" {
      // コミットしていない変更（untracked を含む）があれば、取り込む変更と重なるかもしれないので確かめる。
      if pane.hasChanges,
        !(await app.confirm(
          "git pull",
          tr("git_commands.pull.with_changes"),
          yes: tr("git_commands.pull.yes")
        ))
      {
        return
      }
      try await gitInTerminal(pane.git, root, ["pull"])
      return
    }
    if command == "git push" {
      try await gitInTerminal(pane.git, root, ["push"])
      return
    }
    if command == "git push --force-with-lease" {
      // リモートを上書きするので、ブランチ名を出して確かめる。
      let branch = pane.branch
      let ok = await app.confirm(
        "git push --force-with-lease",
        tr(
          "git_commands.force_push.message",
          ["branch": branch.map { tr("git_commands.force_push.branch", ["branch": $0]) } ?? ""]
        ),
        yes: tr("git_commands.force_push.yes")
      )
      if ok {
        try await gitInTerminal(pane.git, root, ["push", "--force-with-lease"])
      }
      return
    }
    if command == "git restore" {
      let paths = distinct(lines.map { $0.path })
      let label = paths.count == 1 ? tr("git_commands.label.one", ["path": paths[0]]) : tr("git_commands.label.files", ["count": paths.count])
      let ok = await app.confirm(
        "git restore",
        tr("git_commands.restore.message", ["label": label]),
        yes: tr("git_commands.restore.yes")
      )
      if ok {
        try await app.withProgress(tr("git_commands.running", ["command": "git restore"])) { try await pane.git.restore(root, paths) }
        pane.marks.clear()
        // ファイルの中身が変わるので、左の窓も読み直す（Git の窓は _run が終わったときに読み直す）。
        await onFilesChanged()
      }
      return
    }
    let add = command == "git add"
    // 同じファイルが staged と not staged の両方でマークされていても、1回だけ渡す。
    // add の取り消しでは、名前の変更は元と新しいほうの両方を戻す。
    let paths = distinct(lines.flatMap { add ? [$0.path] : $0.paths })
    try await app.withProgress(tr("git_commands.running", ["command": command])) {
      if add {
        try await pane.git.add(root, paths)
      } else {
        try await pane.git.restoreStaged(root, paths)
      }
    }
    pane.marks.clear()
    // git status の読み直しは、_run が終わったときに行う。
  }

  /// 左の窓の対象（マークした項目、なければカーソルの項目）の git の状態に合わせて、add・restore・rm を選んで実行する。
  /// git status に出てこない変更のないファイルも、rm できる。コマンドは、使える対象だけに実行する。
  func leftCommand(_ pane: GitPane, _ left: Pane) async throws {
    guard let dir = pane.dir, pane.root != nil, pane.ready, let left = left as? PathPane, left.ready, !left.readOnly else {
      return
    }
    let targets = left.targetsFor()
    if targets.isEmpty {
      return
    }
    // Git の窓は左で開いているフォルダーで git を実行するので、パスはそこからの相対パスにする。
    let paths = distinct(targets.map { left.context.relative(left.pathOfMark($0), from: dir) })
    let git = pane.git
    let states = try await app.withProgress(tr("git_commands.running", ["command": "git status"])) { try await git.pathStates(dir, paths) }
    func `where`(_ test: (GitPathState) -> Bool) -> [String] {
      paths.filter { test(states[$0]!) }
    }
    let choices: [(command: String, paths: [String])] = [
      ("git add", `where` { $0.untracked || $0.modified }),
      ("git restore --staged", `where` { $0.staged }),
      // ファイルの履歴は、管理下のファイル1つだけ。
      (
        "git log",
        targets.count == 1 && !targets[0].entry.isDir && states[paths[0]]!.tracked ? [paths[0]] : []
      ),
      ("git restore", `where` { $0.modified }),
      ("git rm", `where` { $0.tracked }),
      ("git rm --cached", `where` { $0.tracked }),
    ].filter { !$0.paths.isEmpty }
    if choices.isEmpty {
      app.showStatus(tr("git_commands.left.nothing"))
      return
    }
    // 使えるのが対象の一部だけなら、その数を添える。
    guard let choice = await app.askChoice(
      "Git",
      choices.map { $0.paths.count == paths.count ? $0.command : tr("git_commands.left.command_with_count", ["command": $0.command, "count": $0.paths.count]) },
      closeKey: { key in key.name == "f12" || key.isLetter("g") },
      closeAtEdges: true
    ) else {
      return
    }
    let command = choices[choice].command
    let chosen = choices[choice].paths
    let label = chosen.count == 1 ? tr("git_commands.label.one", ["path": chosen[0]]) : tr("git_commands.label.items", ["count": chosen.count])
    switch command {
    case "git add":
      try await app.withProgress(tr("git_commands.running", ["command": "git add"])) { try await git.add(dir, chosen) }
    case "git restore --staged":
      try await app.withProgress(tr("git_commands.running", ["command": "git restore --staged"])) { try await git.restoreStaged(dir, chosen) }
    case "git log":
      try await fileLog(git, pane.root!, dir, chosen[0])
      return
    case "git restore":
      if !(await app.confirm(
        "git restore",
        tr("git_commands.restore.message", ["label": label]),
        yes: tr("git_commands.restore.yes")
      )) {
        return
      }
      try await app.withProgress(tr("git_commands.running", ["command": "git restore"])) { try await git.restore(dir, chosen) }
    case "git rm":
      if !(await app.confirm(
        "git rm",
        tr("git_commands.rm.message", ["label": label]),
        yes: tr("git_commands.rm.yes")
      )) {
        return
      }
      try await app.withProgress(tr("git_commands.running", ["command": "git rm"])) { try await git.remove(dir, chosen, cached: false) }
    case "git rm --cached":
      try await app.withProgress(tr("git_commands.running", ["command": "git rm --cached"])) { try await git.remove(dir, chosen, cached: true) }
    default:
      break
    }
    left.marks.clear()
    // restore・rm でファイルが変わるので、左の窓も読み直す（Git の窓は _run が終わったときに読み直す）。
    await onFilesChanged()
  }

  /// [path]（[dir] からの相対パス）の履歴を出す。差分は、リポジトリの一番上 [root] からのパスで読む。
  private func fileLog(_ git: Git, _ root: String, _ dir: String, _ path: String) async throws {
    let commits = try await app.withProgress(tr("git_commands.running", ["command": "git log"])) { try await git.fileLog(dir, path) }
    await app.showModal { (close: @escaping (()) -> Void) in FileLogView(app, close, git, root, dir, path, commits) }
  }

  /// ブランチ [current] の新しい名前を聞いて（初期値は今の名前）、リネームする。
  private func renameBranch(_ pane: GitPane, _ root: String, _ current: String) async throws {
    let name = await app.input(
      "git branch -m",
      message: tr("git_commands.rename.new_name"),
      initial: current,
      validate: { value in value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? tr("git_commands.branch.name_required") : nil }
    )
    guard let to = name?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty, to != current else {
      return
    }
    if !(try await pane.git.isValidBranchName(root, to)) {
      await app.showError(tr("git_commands.branch.invalid_name", ["name": to]))
      return
    }
    try await app.withProgress(tr("git_commands.running", ["command": "git branch -m"])) { try await pane.git.renameBranch(root, current, to) }
    // git status の読み直しは、_run が終わったときに行う。
  }

  /// git の [args]（push・pull など）を、枠の中の端末で実行する（パスワードや SSH のパスフレーズを聞かれたり、エディタが開いたりしても操作できるように）。
  /// 終わったら Enter で戻る。
  private func gitInTerminal(_ git: Git, _ root: String, _ args: [String]) async throws {
    let (program, argv) = try git.commandLine(["-C", root] + args, tty: true)
    await runInTerminal(app, "\(git.placeOf(root)) $ \((["git"] + args).joined(separator: " "))", program, argv)
  }
}
