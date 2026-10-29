import Darwin
import Foundation

/// git コマンド。この Mac の git（[locate]）か、SSH の接続先の git（[overSsh]）を実行する。
final class Git {
  private init(_ executable: String, ssh: Ssh? = nil) {
    self.executable = executable
    self.ssh = ssh
  }

  /// git の実行ファイルの場所。接続先の git では「git」（接続先の PATH から探す）。
  let executable: String

  /// 接続先の git なら、その接続。この Mac の git なら nil。
  let ssh: Ssh?

  /// PATH から git を探す。見つからなければ nil。
  /// macOS の /usr/bin/git は開発ツールを呼び出すだけの入口で、開発ツールがないとインストールのダイアログが出るので、
  /// 開発ツールが入っているときだけ使う。
  static func locate() async throws -> Git? {
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":") {
      if dir.isEmpty {
        continue
      }
      let path = p.join(dir, "git")
      var info = stat()
      // 誰かに実行権限のある通常のファイル。
      if stat(path, &info) != 0 || info.st_mode & S_IFMT != S_IFREG || info.st_mode & 0x49 == 0 {
        continue
      }
      if path == "/usr/bin/git" {
        let tools = try await runProcess("/usr/bin/xcode-select", ["-p"])
        if tools.exitCode != 0 {
          continue
        }
      }
      return Git(path)
    }
    return nil
  }

  /// [ssh] の接続先の git。接続先の sh の PATH に git がなければ nil。
  static func overSsh(_ ssh: Ssh) async throws -> Git? {
    let found = String(decoding: try await ssh.run("command -v git || true"), as: UTF8.self)
    return trim(found).isEmpty ? nil : Git("git", ssh: ssh)
  }

  /// git を [args] で実行するプログラムと引数。[tty] なら、接続先の git には端末を割り当てる（認証を聞かれても答えられるように）。
  /// 接続先の git で、引数を sh の言葉にできない（改行を含むなど）ときは失敗する。
  func commandLine(_ args: [String], tty: Bool = false) throws -> (String, [String]) {
    if let remote = ssh {
      return (Ssh.executable, try remote.gitArgs(args, tty: tty))
    }
    return (executable, args)
  }

  /// 見出しなどに出す [root] の場所。接続先なら「host:パス」。
  func placeOf(_ root: String) -> String {
    if let remote = ssh {
      return "\(remote.host):\(root)"
    }
    return root
  }

  private func exec(_ args: [String]) async throws -> ProcResult {
    let (program, argv) = try commandLine(args)
    return try await runProcess(program, argv)
  }

  private func run(_ dir: String, _ args: [String]) async throws -> ProcResult { try await exec(["-C", dir] + args) }

  /// [exec] と同じく実行し、[input] を標準入力に渡す。
  private func execInput(_ args: [String], _ input: Data) async throws -> ProcResult {
    let (program, argv) = try commandLine(args)
    return try await runProcess(program, argv, input: input)
  }

  /// 失敗した git の [ProcessError]。メッセージは標準エラー出力。
  private func failure(_ args: [String], _ result: ProcResult) -> ProcessError {
    ProcessError(executable, args, trim(result.stderr), result.exitCode)
  }

  /// [run] して、失敗したら [ProcessError]。成功したら標準出力。
  private func output(_ dir: String, _ args: [String]) async throws -> String {
    let result = try await run(dir, args)
    if result.exitCode != 0 {
      throw failure(Array(args.prefix(2)), result)
    }
    return Git.decode(result.stdoutData)
  }

  /// [dir] がリポジトリの作業ツリーの中なら、その一番上のフォルダーと git status。外なら nil。
  /// SSH の接続先では1回ごとに往復の時間がかかるので、一番上のフォルダー・git status・設定を同時に読む
  /// （git status --porcelain のパスは、サブフォルダーで実行しても一番上からのパス）。
  func statusAt(_ dir: String) async throws -> (String, GitStatus)? {
    async let topRun = run(dir, ["rev-parse", "--show-toplevel"])
    async let statusRun = run(dir, ["status", "--porcelain=v1", "-z", "--branch"])
    async let configRun = run(dir, ["config", "-l", "-z"])
    let (top, status, config) = try await (topRun, statusRun, configRun)
    if top.exitCode != 0 {
      return nil
    }
    if status.exitCode != 0 {
      throw failure(["status"], status)
    }
    let root = trim(Git.decode(top.stdoutData))
    let parsed = parseGitStatus(Git.decode(status.stdoutData))
    let info = repositoryInfo(parseGitConfig(Git.decode(config.stdoutData)), parsed.branch)
    return (
      root,
      GitStatus(
        parsed.branch,
        parsed.entries,
        pushRemote: info.pushRemote,
        remote: info.remote,
        repository: info.repository ?? p.basename(root),
        user: info.user
      )
    )
  }

  /// 登録されているリモートの名前（git remote）。
  func remotes(_ root: String) async throws -> [String] {
    let result = try await run(root, ["remote"])
    if result.exitCode != 0 {
      throw failure(["remote"], result)
    }
    return splitOn(Git.decode(result.stdoutData), "\n").map(trim).filter { !$0.isEmpty }
  }

  /// [branch] を [remote] に紐付ける（git push -u と同じ設定）。
  /// git branch --set-upstream-to と違い、リモートにまだ同じ名前のブランチがなくても設定できる。
  /// 紐付けるリモートのブランチ（branch.<名前>.merge）がまだなければ、同じ名前のブランチにする。
  func setBranchRemote(_ root: String, _ branch: String, _ remote: String) async throws {
    try await config(root, ["branch.\(branch).remote", remote])
    let merge = try await run(root, ["config", "--get", "branch.\(branch).merge"])
    if merge.exitCode != 0 {
      try await config(root, ["branch.\(branch).merge", "refs/heads/\(branch)"])
    }
  }

  /// [branch] の push 先だけを [remote] にする（branch.<名前>.pushRemote）。[remote] が nil なら設定を消す。
  func setBranchPushRemote(_ root: String, _ branch: String, _ remote: String?) async throws {
    if let remote {
      try await config(root, ["branch.\(branch).pushRemote", remote])
    } else {
      try await unsetConfig(root, "branch.\(branch).pushRemote")
    }
  }

  /// [branch] の紐付けを外す（git branch --unset-upstream と同じ。紐付けるリモートとブランチの両方を消す）。
  func unsetBranchRemote(_ root: String, _ branch: String) async throws {
    try await unsetConfig(root, "branch.\(branch).remote")
    try await unsetConfig(root, "branch.\(branch).merge")
  }

  /// 設定を消す。もともと設定がなくても失敗にしない。
  private func unsetConfig(_ root: String, _ key: String) async throws {
    let result = try await run(root, ["config", "--unset", key])
    // 5 は「もともと設定がない」。
    if result.exitCode != 0 && result.exitCode != 5 {
      throw failure(["config"], result)
    }
  }

  private func config(_ root: String, _ args: [String]) async throws {
    let result = try await run(root, ["config"] + args)
    if result.exitCode != 0 {
      throw failure(["config"], result)
    }
  }

  /// [root] のリポジトリで、[paths]（リポジトリの一番上からのパス）を git add する。
  func add(_ root: String, _ paths: [String]) async throws { try await change(root, ["add", "--"] + paths) }

  /// [root] のリポジトリで、[paths] の add していない変更を捨てて、add した状態（add していなければ最後のコミット）に戻す。
  func restore(_ root: String, _ paths: [String]) async throws { try await change(root, ["restore", "--"] + paths) }

  /// [dir] で、[paths] を git rm -r する。[cached] なら git の管理から外すだけで、ファイルは残す。
  func remove(_ dir: String, _ paths: [String], cached: Bool) async throws {
    try await change(dir, ["rm", "-r", "--quiet"] + (cached ? ["--cached"] : []) + ["--"] + paths)
  }

  /// [dir] から見た [paths]（フォルダーを含む）それぞれの git の状態。キーは [paths] のまま。
  /// フォルダーは、中のファイルのどれかがその状態なら、その状態とする。リポジトリの外のパスは、どの状態でもない。
  func pathStates(_ dir: String, _ paths: [String]) async throws -> [String: GitPathState] {
    func output(_ args: [String]) async throws -> String {
      let result = try await exec(["--literal-pathspecs", "-C", dir] + args)
      if result.exitCode != 0 {
        throw failure(Array(args.prefix(1)), result)
      }
      return Git.decode(result.stdoutData)
    }

    // git status・ls-files のパスはリポジトリの一番上から。[dir] のその中での場所（末尾は「/」）を前に付けて揃える。
    let prefix = trim(try await output(["rev-parse", "--show-prefix"]))
    let status = parsePathStatus(try await output(["status", "--porcelain=v1", "-z", "--"] + paths))
    let tracked = splitOn(try await output(["ls-files", "-z", "--"] + paths), "\0").filter { !$0.isEmpty }
    var states: [String: GitPathState] = [:]
    for path in paths {
      states[path] = GitPathState.of(PathContext.posix.normalize("\(prefix)\(path)"), status, tracked)
    }
    return states
  }

  /// [root] のリポジトリで、[paths] の git add を取り消す（作業ツリーのファイルはそのまま）。
  /// まだコミットがないリポジトリでは git restore --staged が使えないので、git rm --cached で取り消す。
  func restoreStaged(_ root: String, _ paths: [String]) async throws {
    let head = try await run(root, ["rev-parse", "--verify", "--quiet", "HEAD"])
    try await change(
      root,
      head.exitCode == 0
        ? ["restore", "--staged", "--"] + paths
        : ["rm", "--cached", "-r", "--quiet", "--"] + paths
    )
  }

  /// [root] のリポジトリの [paths] の差分。[staged] なら add した変更（git diff --cached）、でなければ add していない変更。
  func diff(_ root: String, _ paths: [String], staged: Bool) async throws -> [DiffFile] {
    let result = try await exec(
      [
        "--literal-pathspecs",
        "-C",
        root,
        // 日本語などの名前を「\343...」のようにしない。
        "-c",
        "core.quotepath=false",
        "diff",
        "--no-color",
        "--no-ext-diff",
      ] + (staged ? ["--cached"] : []) + ["--"] + paths
    )
    if result.exitCode != 0 {
      throw failure(["diff"], result)
    }
    return parseGitDiff(Git.decode(result.stdoutData))
  }

  /// [root] のリポジトリの、まだ git に登録していない（untracked）[paths] の中身を、全行を追加した差分として返す。
  /// フォルダーは、中の untracked のファイル（.gitignore で除くものを除く）ごとに分ける。
  func diffUntracked(_ root: String, _ paths: [String]) async throws -> [DiffFile] {
    let listed = try await exec(
      ["--literal-pathspecs", "-C", root, "ls-files", "--others", "--exclude-standard", "-z", "--"] + paths
    )
    if listed.exitCode != 0 {
      throw failure(["ls-files"], listed)
    }
    let files = splitOn(Git.decode(listed.stdoutData), "\0").filter { !$0.isEmpty }
    var result: [DiffFile] = []
    for file in files {
      // 空のファイルと比べる。違いがあると終了コードは 1 になる（失敗ではない）。
      let diff = try await exec([
        "-C",
        root,
        "-c",
        "core.quotepath=false",
        "diff",
        "--no-index",
        "--no-color",
        "--no-ext-diff",
        "--",
        "/dev/null",
        file,
      ])
      if diff.exitCode > 1 {
        throw failure(["diff"], diff)
      }
      // 空のファイルは差分が出ないので、中身のないページにする。
      result += diff.exitCode == 0 ? [DiffFile(file)] : parseGitDiff(Git.decode(diff.stdoutData))
    }
    return result
  }

  /// [root] のリポジトリで、add した変更を [message] でコミットする。メッセージは標準入力で渡す（記号や改行をそのまま扱う）。
  func commit(_ root: String, _ message: String) async throws {
    let (program, argv) = try commandLine(["-C", root, "commit", "--file=-"])
    let result = try await runProcess(program, argv, input: Data(message.utf8))
    if result.exitCode != 0 {
      // 「コミットするものがない」などは標準出力に出るので、両方を見せる。
      throw ProcessError(executable, ["commit"], trim([result.stderr, result.stdout].joined(separator: "\n")), result.exitCode)
    }
  }

  /// [name] がブランチ名として使えるか（git check-ref-format --branch）。
  func isValidBranchName(_ root: String, _ name: String) async throws -> Bool {
    try await run(root, ["check-ref-format", "--branch", name]).exitCode == 0
  }

  /// [root] のリポジトリで、ブランチ [from] を [to] に名前を変える。紐付け先などの設定も git が引き継ぐ。
  func renameBranch(_ root: String, _ from: String, _ to: String) async throws {
    let result = try await run(root, ["branch", "-m", "--", from, to])
    if result.exitCode != 0 {
      throw failure(["branch"], result)
    }
  }

  /// 手元のブランチの名前。
  func localBranches(_ root: String) async throws -> [String] { try await refs(root, "refs/heads/") }

  /// [remote] のブランチの名前（「origin/main」の形。origin/HEAD は除く）。最後に fetch したときのもの。
  func remoteBranches(_ root: String, _ remote: String) async throws -> [String] {
    try await refs(root, "refs/remotes/\(remote)/").filter { $0 != "\(remote)/HEAD" && $0 != remote }
  }

  private func refs(_ root: String, _ prefix: String) async throws -> [String] {
    let result = try await run(root, ["for-each-ref", "--format=%(refname:short)", prefix])
    if result.exitCode != 0 {
      throw failure(["for-each-ref"], result)
    }
    return splitOn(Git.decode(result.stdoutData), "\n").map(trim).filter { !$0.isEmpty }
  }

  /// ブランチ [name] に切り替える。[track]（「origin/xxx」）があれば、それに紐付けた手元のブランチ [name] を作って切り替える。
  /// [create] なら、今の場所から新しいブランチ [name] を作って切り替える。
  func switchBranch(_ root: String, _ name: String, track: String? = nil, create: Bool = false) async throws {
    let target: [String] =
      if let track { ["--create", name, "--track", track] } else if create { ["--create", name] } else { [name] }
    let result = try await run(root, ["switch"] + target)
    if result.exitCode != 0 {
      throw failure(["switch"], result)
    }
  }

  /// 今のブランチのコミットの履歴（新しい順に [limit] 件まで）。コミットがまだなければ空。
  func log(_ root: String, limit: Int = 1000) async throws -> [GitCommit] {
    let result = try await run(root, [
      "log",
      "-z",
      "-n",
      "\(limit)",
      "--date=format:%Y-%m-%d %H:%M",
      "--format=%H%x1f%h%x1f%ad%x1f%an%x1f%s",
    ])
    if result.exitCode != 0 {
      // まだコミットがないブランチ。
      return []
    }
    return parseGitLog(Git.decode(result.stdoutData))
  }

  /// [path]（[dir] からの相対パス）が変わったコミット（新しい順に [limit] 件まで）。名前の変更もたどる。
  /// マージのコミットは、1つ目の親との差で見る。
  func fileLog(_ dir: String, _ path: String, limit: Int = 1000) async throws -> [FileCommit] {
    let result = try await exec([
      "--literal-pathspecs",
      "-C",
      dir,
      "log",
      "--follow",
      "-z",
      "--name-status",
      "--diff-merges=first-parent",
      "-n",
      "\(limit)",
      "--date=format:%Y-%m-%d %H:%M",
      "--format=%x1e%H%x1f%h%x1f%ad%x1f%an%x1f%s",
      "--",
      path,
    ])
    if result.exitCode != 0 {
      // まだコミットがないブランチ。
      return []
    }
    return parseFileLog(Git.decode(result.stdoutData))
  }

  /// コミット [hash] での [file] の差分。名前の変更は、元と新しいパスの両方を渡して、名前の変更として出す。
  func fileDiff(_ root: String, _ hash: String, _ file: CommitFile) async throws -> [DiffFile] {
    let result = try await exec(
      [
        "--literal-pathspecs",
        "-C",
        root,
        "-c",
        "core.quotepath=false",
        "show",
        "--no-color",
        "--no-ext-diff",
        "--format=",
        "--diff-merges=first-parent",
        "-M",
        hash,
        "--",
      ] + (file.from.map { [$0] } ?? []) + [file.path]
    )
    if result.exitCode != 0 {
      throw failure(["show"], result)
    }
    return parseGitDiff(Git.decode(result.stdoutData))
  }

  /// [oldest] から [newest] までの差分の元（[oldest] の1つ目の親。親がない最初のコミットなら空のツリー）。
  private func rangeBase(_ root: String, _ oldest: String) async throws -> String {
    let parent = try await run(root, ["rev-parse", "--verify", "-q", "\(oldest)^"])
    if parent.exitCode == 0 {
      return trim(Git.decode(parent.stdoutData))
    }
    let empty = try await execInput(["-C", root, "hash-object", "-t", "tree", "--stdin"], Data())
    return trim(Git.decode(empty.stdoutData))
  }

  /// コミット [oldest] から [newest] まで（間のコミットを含む）で変わったファイル。
  func rangeFiles(_ root: String, _ oldest: String, _ newest: String) async throws -> [CommitFile] {
    let base = try await rangeBase(root, oldest)
    return parseNameStatus(try await output(root, ["diff", "-z", "--name-status", "-M", base, newest]))
  }

  /// コミット [oldest] から [newest] まで（間のコミットを含む）の差分。[paths] があれば、そのパスだけ。
  /// 名前の変更は、元と新しいパスの両方を [paths] に渡すと、名前の変更として出る。
  func rangeDiff(_ root: String, _ oldest: String, _ newest: String, paths: [String] = []) async throws -> [DiffFile] {
    let base = try await rangeBase(root, oldest)
    let result = try await exec(
      [
        "--literal-pathspecs",
        "-C",
        root,
        "-c",
        "core.quotepath=false",
        "diff",
        "--no-color",
        "--no-ext-diff",
        "-M",
        base,
        newest,
      ] + (paths.isEmpty ? [] : ["--"] + paths)
    )
    if result.exitCode != 0 {
      throw failure(["diff"], result)
    }
    return parseGitDiff(Git.decode(result.stdoutData))
  }

  /// 今の位置（HEAD）の履歴にあるコミット [hash] の作者とメッセージを書き換える準備。
  /// [hash] と、そのあとに続く（作り直す）コミットを読む。
  func prepareAuthorRewrite(_ root: String, _ hash: String) async throws -> AuthorRewrite {
    async let headRun = output(root, ["rev-parse", "--verify", "HEAD"])
    async let refRun = run(root, ["symbolic-ref", "-q", "HEAD"])
    async let afterRun = output(root, ["rev-list", "--ancestry-path", "--topo-order", "--reverse", "\(hash)..HEAD"])
    let (head, ref, after) = try await (headRun, refRun, afterRun)
    let ancestor = try await run(root, ["merge-base", "--is-ancestor", hash, "HEAD"])
    if ancestor.exitCode != 0 {
      throw GitException("今の位置の履歴にないコミットは書き換えられません。")
    }
    let hashes = [hash] + splitOn(after, "\n").map(trim).filter { !$0.isEmpty }
    let read = try await execInput(["-C", root, "cat-file", "--batch"], Data((hashes.joined(separator: "\n") + "\n").utf8))
    if read.exitCode != 0 {
      throw failure(["cat-file"], read)
    }
    let commits = parseCatFileBatch([UInt8](read.stdoutData))
    if commits.count != hashes.count {
      throw GitException("コミットを読めませんでした。")
    }
    return AuthorRewrite(
      head: trim(head),
      ref: ref.exitCode == 0 ? trim(Git.decode(ref.stdoutData)) : nil,
      target: commits[0],
      after: Array(commits[1...])
    )
  }

  /// [rewrite] のコミットの作者を [name]・[email] に、メッセージを [message]（nil なら元のまま）にして作り直し、
  /// そのあとのコミットも親を付け替えて作り直して、今のブランチ（ブランチにいなければ HEAD）を付け替える。
  /// 中身（ツリー）とコミッターは変えないので、作業ツリーと index はそのまま。
  func rewriteAuthor(_ root: String, _ rewrite: AuthorRewrite, name: String, email: String, message: String? = nil) async throws {
    var renamed: [String: String] = [:]
    func write(_ commit: RawCommit, _ text: [UInt8]) async throws {
      let result = try await execInput(["-C", root, "hash-object", "-t", "commit", "-w", "--stdin"], Data(text))
      if result.exitCode != 0 {
        throw failure(["hash-object"], result)
      }
      renamed[commit.hash] = trim(Git.decode(result.stdoutData))
    }

    try await write(rewrite.target, rewrite.target.withAuthor(name, email, message: message))
    for commit in rewrite.after {
      try await write(commit, commit.withParents(renamed))
    }
    let reason = "fm-ee2e: コミットの作者を書き換え"
    guard let newHead = renamed[rewrite.head] else {
      throw GitException("コミットを読めませんでした。")
    }
    let target = rewrite.ref.map { [$0] } ?? ["--no-deref", "HEAD"]
    try await change(root, ["update-ref", "-m", reason] + target + [newHead, rewrite.head])
  }

  /// コミット [hash] が、リモートのブランチ（git fetch で知っているもの）に入っているか。
  func isPushed(_ root: String, _ hash: String) async throws -> Bool {
    !trim(try await output(root, ["branch", "-r", "--contains", hash])).isEmpty
  }

  /// コミット [hash] で変わったファイル（git show --name-status）。マージのコミットは、1つ目の親との差。
  func commitFiles(_ root: String, _ hash: String) async throws -> [CommitFile] {
    let result = try await run(root, ["show", "-z", "--name-status", "--format=", "--diff-merges=first-parent", hash])
    if result.exitCode != 0 {
      throw failure(["show"], result)
    }
    return parseNameStatus(Git.decode(result.stdoutData))
  }

  /// コミット [hash] の差分（ファイルごと）。マージのコミットは、1つ目の親との差。
  func commitDiff(_ root: String, _ hash: String) async throws -> [DiffFile] {
    let result = try await run(root, [
      "-c",
      "core.quotepath=false",
      "show",
      "--no-color",
      "--no-ext-diff",
      "--format=",
      "--diff-merges=first-parent",
      hash,
    ])
    if result.exitCode != 0 {
      throw failure(["show"], result)
    }
    return parseGitDiff(Git.decode(result.stdoutData))
  }

  /// インデックスを変える git コマンド。パスの「*」などをワイルドカードとして扱わないよう、--literal-pathspecs を付ける。
  private func change(_ root: String, _ args: [String]) async throws {
    let result = try await exec(["--literal-pathspecs", "-C", root] + args)
    if result.exitCode != 0 {
      throw failure(Array(args.prefix(2)), result)
    }
  }

  private static func decode(_ bytes: Data) -> String { String(decoding: bytes, as: UTF8.self) }
}

/// git status の結果。
struct GitStatus {
  init(_ branch: String?, _ entries: [GitStatusEntry], pushRemote: String? = nil, remote: String? = nil, repository: String? = nil, user: String? = nil) {
    self.branch = branch
    self.entries = entries
    self.pushRemote = pushRemote
    self.remote = remote
    self.repository = repository
    self.user = user
  }

  /// ブランチ名。ブランチにいない（detached HEAD）ときなどは git の表示のまま。
  let branch: String?
  let entries: [GitStatusEntry]

  /// push 先だけを別にするリモート（branch.<名前>.pushRemote）。設定されていなければ「`<no branch.pushRemote>`」。
  /// ブランチにいないときは nil。
  let pushRemote: String?

  /// ブランチに紐付いているリモートの名前。紐付いていなければ「(no upstream)」、リモートがなければ「(no remote)」。
  /// ブランチにいないときは nil。
  let remote: String?

  /// リポジトリ名（[Git.statusAt] のときだけ。リモートの URL から取った名前か、手元のフォルダー名）。
  let repository: String?

  /// コミットに使われるユーザー（「名前<メール>」。[Git.statusAt] のときだけ。設定がなければ nil）。
  let user: String?
}

/// リモートの URL から、リポジトリ名を取る。
/// https://github.com/owner/name.git・git@github.com:owner/name.git・ssh://git@host/owner/name なら owner/name、
/// 手元のフォルダーなどパスが1段なら、その名前。
/// `git config -l -z` の出力を読む（「キー\n値\0」が続く。値のないキーは「キー\0」）。同じキーは後のものを使う。
/// キーの節と名前は小文字で出る（branch.<名前>.pushRemote は branch.<名前>.pushremote）。
func parseGitConfig(_ output: String) -> [String: String] {
  var config: [String: String] = [:]
  for item in splitOn(output, "\0") where !item.isEmpty {
    if let at = indexOf(item, "\n") {
      config[slice(item, 0, at)] = slice(item, at + 1)
    } else {
      config[item] = ""
    }
  }
  return config
}

/// git の設定から読む、Git の窓の上に出すもの。
typealias RepositoryInfo = (remote: String?, pushRemote: String?, repository: String?, user: String?)

/// [config]（[parseGitConfig]）と今のブランチ [branch] から、Git の窓の上に出すものを決める。
/// - remote: ブランチの紐付け先のリモート。なければ「(no upstream)」、リモートが1つもなければ「(no remote)」。
/// - pushRemote: push 先だけを別にするリモート。なければ「`<no branch.pushRemote>`」。
/// - repository: 紐付け先のリモートの URL から取った名前（github.com/owner/name なら owner/name）。取れなければ nil。
/// - user: コミットに使われる「名前 <メール>」。どちらもなければ nil。
/// ブランチにいないとき、remote と pushRemote は nil。
func repositoryInfo(_ config: [String: String], _ branch: String?) -> RepositoryInfo {
  func value(_ key: String) -> String? {
    if let v = config[key].map(trim), !v.isEmpty {
      return v
    }
    return nil
  }
  let onBranch = branch != nil && branch != "HEAD"
  let branch = branch ?? ""
  // リモートの設定は remote.<名前>.<項目>（remote.pushdefault のような2つ区切りのものは除く）。
  let hasRemote = config.keys.contains { starts($0, "remote.") && indexOf($0, ".", from: 7) != nil }
  let remote = !onBranch ? nil : value("branch.\(branch).remote") ?? (hasRemote ? "(no upstream)" : "(no remote)")
  let url = remote == nil || starts(remote!, "(") || remote == "." ? nil : value("remote.\(remote!).url")
  let repository = url == nil ? "" : repositoryNameFromUrl(url!)
  let name = value("user.name") ?? ""
  let email = value("user.email") ?? ""
  return (
    remote: remote,
    pushRemote: !onBranch ? nil : value("branch.\(branch).pushremote") ?? "<no branch.pushRemote>",
    repository: repository.isEmpty ? nil : repository,
    user: name.isEmpty && email.isEmpty
      ? nil
      : email.isEmpty
      ? name
      : "\(name.isEmpty ? "" : "\(name) ")<\(email)>"
  )
}

func repositoryNameFromUrl(_ url: String) -> String {
  var path = trim(url)
  while ends(path, "/") {
    path = slice(path, 0, path.utf8.count - 1)
  }
  if ends(path, ".git") {
    path = slice(path, 0, path.utf8.count - 4)
  }
  if let scheme = indexOf(path, "://") {
    // ホスト名を外す。
    let slash = indexOf(path, "/", from: scheme + 3)
    path = slash == nil ? "" : slice(path, slash! + 1)
  } else if hasHostPrefix(path) {
    // git@github.com:owner/name の形。
    path = slice(path, indexOf(path, ":")! + 1)
  }
  let parts = splitOn(path, "/").filter { !$0.isEmpty }
  return parts.count >= 2 ? "\(parts[parts.count - 2])/\(parts[parts.count - 1])" : parts.joined()
}

/// 正規表現 ^[^/]+: に当たるか（「/」より前の2文字目以降に「:」がある）。
private func hasHostPrefix(_ path: String) -> Bool {
  for (i, byte) in path.utf8.enumerated() {
    if byte == UInt8(ascii: "/") {
      return false
    }
    if byte == UInt8(ascii: ":") && i >= 1 {
      return true
    }
  }
  return false
}

/// git status の1行。
struct GitStatusEntry {
  init(_ code: String, _ path: String, from: String? = nil) {
    self.code = code
    self.path = path
    self.from = from
  }

  /// 2文字の状態（左がステージ、右が作業ツリー。例: "M "、" M"、"??"）。
  let code: String

  /// リポジトリの一番上からのパス。フォルダーは「/」で終わる。
  let path: String

  /// 名前の変更・コピーの元のパス。
  let from: String?

  /// ステージした変更がある（git status で緑になるもの）。
  var staged: Bool {
    let x = unit(code, 0)
    return x != " " && x != "?" && x != "!"
  }
}

/// git の窓の1行の種類。
enum GitLineKind {
  /// リポジトリ名。staged などと同じ見出しの行で、カーソルは乗らない。
  case repository

  /// push 先だけを別にするリモート（branch.<名前>.pushRemote）。
  case pushRemote

  /// ブランチに紐付いているリモートの名前。
  case remote

  /// ブランチ名。
  case branch

  /// ブロックの見出し（staged など）。カーソルは乗らない。
  case heading

  /// ファイル。
  case file

  /// 変更がないときの案内。カーソルは乗らない。
  case note
}

/// git の窓の1行。
/// git status --porcelain=v1 -z の1項目（パスはリポジトリの一番上から。untracked のフォルダーは末尾が「/」）。
typealias PathStatus = (path: String, staged: Bool, modified: Bool, untracked: Bool)

/// git status --porcelain=v1 -z の出力を読む。名前の変更・コピーは新しいほうのパスだけ。.gitignore で除いたもの（!!）は除く。
func parsePathStatus(_ out: String) -> [PathStatus] {
  let items = splitOn(out, "\0")
  var result: [PathStatus] = []
  var i = 0
  while i < items.count {
    defer { i += 1 }
    let item = items[i]
    if item.utf16.count < 4 {
      continue
    }
    let (x, y) = (unit(item, 0), unit(item, 1))
    if x == "R" || x == "C" {
      // 次の項目は元のパス。
      i += 1
    }
    if x == "!" {
      continue
    }
    result.append((
      path: slice(item, 3),
      staged: x != " " && x != "?",
      modified: y != " " && y != "?",
      untracked: x == "?"
    ))
  }
  return result
}

/// パス（フォルダーを含む）の git の状態。
struct GitPathState {
  init(staged: Bool = false, modified: Bool = false, untracked: Bool = false, tracked: Bool = false) {
    self.staged = staged
    self.modified = modified
    self.untracked = untracked
    self.tracked = tracked
  }

  /// リポジトリの一番上からの [path] の状態。[status] は git status、[tracked] は git ls-files のパス。
  static func of(_ path: String, _ status: [PathStatus], _ tracked: [String]) -> GitPathState {
    // 同じパスか、[path] のフォルダーの中のパスか、[path] を中に持つ untracked のフォルダー。
    func covers(_ other: String) -> Bool {
      same(other, path) || starts(other, "\(path)/") || (ends(other, "/") && starts(path, other))
    }
    let matched = status.filter { covers($0.path) }
    return GitPathState(
      staged: matched.contains { $0.staged },
      modified: matched.contains { $0.modified },
      untracked: matched.contains { $0.untracked },
      tracked: tracked.contains(where: covers)
    )
  }

  /// add した変更がある。
  let staged: Bool

  /// add していない変更がある（git の管理下のファイル）。
  let modified: Bool

  /// git の管理下にないファイルがある（.gitignore で除いたものを除く）。
  let untracked: Bool

  /// git の管理下のファイルがある。
  let tracked: Bool
}

struct GitStatusLine {
  init(_ kind: GitLineKind, _ text: String, label: String = "", section: String = "", path: String = "", from: String? = nil) {
    self.kind = kind
    self.text = text
    self.label = label
    self.section = section
    self.path = path
    self.from = from
  }

  let kind: GitLineKind

  /// ファイルの行が入っているブロック（staged など）。
  let section: String

  /// ファイルの行の、リポジトリの一番上からのパス（名前の変更は新しいほう）。git に渡す。
  let path: String

  /// 名前の変更の元のパス。
  let from: String?

  /// git に渡すパス。名前の変更は、元と新しいほうの両方。
  var paths: [String] { (from.map { [$0] } ?? []) + [path] }

  /// ブランチ名・見出し・ファイルのパス（名前の変更は「元 -> 新」）。
  let text: String

  /// ファイルの変更の種類（modified など）。
  let label: String

  /// カーソルが乗る行か。
  var selectable: Bool {
    kind == .pushRemote || kind == .remote || kind == .branch || kind == .file
  }
}

/// リポジトリ名・push 先・リモート名・ブランチ名と、staged・unmerged（競合）・not staged・untracked のブロックに分けた行。空のブロックは出さない。
func gitStatusLines(_ status: GitStatus) -> [GitStatusLine] {
  var staged: [GitStatusLine] = []
  var unmerged: [GitStatusLine] = []
  var unstaged: [GitStatusLine] = []
  var untracked: [GitStatusLine] = []
  // ブロックはあとで決まるので、いったんブロック名なしで作り、ブロックに入れるときに付ける。
  func file(_ path: String, _ label: String, from: String? = nil) -> GitStatusLine {
    GitStatusLine(.file, from == nil ? path : "\(from!) -> \(path)", label: label, path: path, from: from)
  }
  for e in status.entries {
    let x = unit(e.code, 0)
    let y = unit(e.code, 1)
    if e.code == "??" {
      untracked.append(file(e.path, ""))
    } else if x == "U" || y == "U" || e.code == "AA" || e.code == "DD" {
      unmerged.append(file(e.path, unmergedLabels[e.code] ?? "conflict"))
    } else {
      if x != " " && x != "!" {
        staged.append(file(e.path, labels[x] ?? x, from: e.from))
      }
      if y != " " && y != "!" {
        unstaged.append(file(e.path, labels[y] ?? y))
      }
    }
  }
  let branch = status.branch
  var lines: [GitStatusLine] = [
    // リポジトリ名の前は、いつも1行空ける（カーソルは乗らない）。
    GitStatusLine(.note, "")
  ]
  if let repository = status.repository {
    lines.append(GitStatusLine(.repository, status.user == nil ? repository : "\(repository)  \(status.user!)"))
  }
  if let pushRemote = status.pushRemote {
    lines.append(GitStatusLine(.pushRemote, pushRemote))
  }
  if let remote = status.remote {
    lines.append(GitStatusLine(.remote, remote))
  }
  lines.append(GitStatusLine(.branch, branch == nil || branch == "HEAD" ? "(no branch)" : branch!))
  // ブランチ名の下は、いつも1行空ける（カーソルは乗らない）。
  lines.append(GitStatusLine(.note, ""))
  for (title, items) in [
    ("staged", staged),
    ("unmerged", unmerged),
    ("not staged", unstaged),
    ("untracked", untracked),
  ] where !items.isEmpty {
    lines.append(GitStatusLine(.heading, title))
    lines += items.map { GitStatusLine($0.kind, $0.text, label: $0.label, section: title, path: $0.path, from: $0.from) }
  }
  if status.entries.isEmpty {
    lines.append(GitStatusLine(.note, "変更はありません"))
  }
  return lines
}

private let labels = ["M": "modified", "A": "new file", "D": "deleted", "R": "renamed", "C": "copied", "T": "type"]

/// 競合の種類（両方で変更・両方で追加など）。一覧の欄に収まるよう、git の表示を短くしたもの。
private let unmergedLabels = [
  "UU": "both mod",
  "AA": "both add",
  "DD": "both del",
  "AU": "add us",
  "UA": "add them",
  "DU": "del us",
  "UD": "del them",
]

/// `git status --porcelain=v1 -z --branch` の出力を読む。
func parseGitStatus(_ output: String) -> GitStatus {
  let fields = splitOn(output, "\0")
  var branch: String?
  var entries: [GitStatusEntry] = []
  var i = 0
  while i < fields.count {
    defer { i += 1 }
    let field = fields[i]
    if starts(field, "## ") {
      // 「## main...origin/main [ahead 1]」「## No commits yet on main」の、ブランチ名の部分。
      // ブランチにいないときは「## HEAD (no branch)」。
      var head = slice(field, 3)
      let noCommits = "No commits yet on "
      if starts(head, noCommits) {
        head = slice(head, noCommits.utf8.count)
      }
      if starts(head, "HEAD (") {
        branch = "HEAD"
      } else {
        let name = indexOf(head, "...").map { slice(head, 0, $0) } ?? head
        branch = splitOn(name, " ")[0]
      }
      continue
    }
    if field.utf16.count < 4 {
      continue
    }
    let code = slice(field, 0, 2)
    let path = slice(field, 3)
    // 名前の変更・コピーは、次の欄に元のパスが続く。
    if code.contains("R") || code.contains("C") {
      var from: String?
      if i + 1 < fields.count {
        i += 1
        from = fields[i]
      }
      entries.append(GitStatusEntry(code, path, from: from))
    } else {
      entries.append(GitStatusEntry(code, path))
    }
  }
  return GitStatus(branch, entries)
}

/// 差分の1ファイル分。
final class DiffFile {
  init(_ path: String, from: String? = nil) {
    self.path = path
    self.from = from
  }

  /// リポジトリの一番上からのパス（消したファイルは元のパス）。
  var path: String

  /// 名前の変更の元のパス。
  var from: String?

  /// バイナリのファイル（中身の差分はない）。
  var binary = false
  var lines: [DiffLine] = []

  var added: Int { lines.count { $0.kind == .added } }
  var removed: Int { lines.count { $0.kind == .removed } }
}

enum DiffLineKind {
  /// 変更の固まりの始まり（@@ の行）。
  case hunk
  case context
  case added
  case removed

  /// 「\ No newline at end of file」など。
  case note
}

/// 差分の1行。行番号は、変更前・変更後のファイルでの番号（ない側は nil）。
struct DiffLine {
  init(_ kind: DiffLineKind, _ text: String, oldNumber: Int? = nil, newNumber: Int? = nil) {
    self.kind = kind
    self.text = text
    self.oldNumber = oldNumber
    self.newNumber = newNumber
  }

  let kind: DiffLineKind

  /// 行の中身（先頭の「+」「-」「 」は除く）。@@ の行は、git が添える関数名など。
  let text: String
  let oldNumber: Int?
  let newNumber: Int?
}

/// 正規表現 ^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@ ?(.*)$ に当たれば、変更前・変更後の始まりの行番号と、残りの文字列。
private func hunkHeader(_ line: String) -> (Int, Int, String)? {
  let bytes = Array(line.utf8)
  var at = 0
  func literal(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard bytes.count - at >= u.count, Array(bytes[at..<at + u.count]) == u else { return false }
    at += u.count
    return true
  }
  func digits() -> Int? {
    let start = at
    while at < bytes.count && bytes[at] >= UInt8(ascii: "0") && bytes[at] <= UInt8(ascii: "9") {
      at += 1
    }
    return at > start ? Int(String(decoding: bytes[start..<at], as: UTF8.self)) ?? 0 : nil
  }
  func count() {
    let start = at
    if literal(","), digits() == nil {
      at = start
    }
  }
  guard literal("@@ -"), let old = digits() else { return nil }
  count()
  guard literal(" +"), let new = digits() else { return nil }
  count()
  guard literal(" @@") else { return nil }
  _ = literal(" ")
  let rest = String(decoding: bytes[at...], as: UTF8.self)
  // 「.」は改行（\r・ ・  を含む）には当たらない。
  if rest.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }) {
    return nil
  }
  return (old, new, rest)
}

/// `git diff --no-color` の出力を、ファイルと行に読み分ける。
func parseGitDiff(_ output: String) -> [DiffFile] {
  var files: [DiffFile] = []
  var file: DiffFile?
  var inHunk = false
  var oldNumber = 0
  var newNumber = 0
  // 「a/」「b/」を外し、git が名前を「"...」で囲んでいれば外す。空白を含む名前には、git が末尾にタブを付ける。
  func strip(_ path: String, _ prefix: String) -> String {
    var path = path
    if ends(path, "\t") {
      path = slice(path, 0, path.utf8.count - 1)
    }
    if path.utf8.count >= 2 && starts(path, "\"") && ends(path, "\"") {
      path = slice(path, 1, path.utf8.count - 1)
    }
    return starts(path, prefix) ? slice(path, prefix.utf8.count) : path
  }

  for line in splitOn(output, "\n") {
    if starts(line, "diff --git ") {
      // 名前は後の「---」「+++」などの行で決める。ここでは仮に、後半（b/ の側）を使う。
      let rest = slice(line, "diff --git ".utf8.count)
      let b = lastIndexOf(rest, " b/")
      file = DiffFile(b.map { slice(rest, $0 + 3) } ?? rest)
      files.append(file!)
      inHunk = false
      continue
    }
    guard let current = file else {
      continue
    }
    if inHunk {
      if starts(line, "+") {
        current.lines.append(DiffLine(.added, slice(line, 1), newNumber: newNumber))
        newNumber += 1
        continue
      }
      if starts(line, "-") {
        current.lines.append(DiffLine(.removed, slice(line, 1), oldNumber: oldNumber))
        oldNumber += 1
        continue
      }
      if starts(line, " ") {
        current.lines.append(DiffLine(.context, slice(line, 1), oldNumber: oldNumber, newNumber: newNumber))
        oldNumber += 1
        newNumber += 1
        continue
      }
      if starts(line, "\\") {
        current.lines.append(DiffLine(.note, trim(slice(line, 1))))
        continue
      }
    }
    if let (old, new, rest) = hunkHeader(line) {
      oldNumber = old
      newNumber = new
      current.lines.append(DiffLine(.hunk, rest, oldNumber: oldNumber, newNumber: newNumber))
      inHunk = true
    } else if starts(line, "+++ ") && line != "+++ /dev/null" {
      current.path = strip(slice(line, 4), "b/")
    } else if starts(line, "--- ") && line != "--- /dev/null" && current.lines.isEmpty {
      // 消したファイルは「+++ /dev/null」なので、元のパスを名前にしておく（+++ があれば上書きされる）。
      current.path = strip(slice(line, 4), "a/")
    } else if starts(line, "rename from ") {
      current.from = slice(line, "rename from ".utf8.count)
    } else if starts(line, "rename to ") {
      current.path = slice(line, "rename to ".utf8.count)
    } else if starts(line, "Binary files ") {
      current.binary = true
    }
  }
  return files
}

/// コミットの履歴の1件。
struct GitCommit {
  init(_ hash: String, _ shortHash: String, _ date: String, _ author: String, _ subject: String) {
    self.hash = hash
    self.shortHash = shortHash
    self.date = date
    self.author = author
    self.subject = subject
  }

  let hash: String
  let shortHash: String

  /// 「2026-10-28 03:05」の形。
  let date: String
  let author: String

  /// メッセージの1行目。
  let subject: String
}

/// `git log -z --format=%H%x1f%h%x1f%ad%x1f%an%x1f%s` の出力を読む。
func parseGitLog(_ output: String) -> [GitCommit] {
  splitOn(output, "\0").compactMap { record in
    let fields = splitOn(record, "\u{1f}")
    guard fields.count == 5 else { return nil }
    return GitCommit(trim(fields[0]), fields[1], fields[2], fields[3], fields[4])
  }
}

struct GitException: Error, CustomStringConvertible {
  init(_ message: String) {
    self.message = message
  }

  let message: String

  var description: String { message }
}

/// コミットの作者を書き換えるときに読んだもの。
struct AuthorRewrite {
  init(head: String, ref: String?, target: RawCommit, after: [RawCommit]) {
    self.head = head
    self.ref = ref
    self.target = target
    self.after = after
  }

  /// 今の位置（HEAD）のコミット。
  let head: String

  /// 今のブランチ（refs/heads/...）。ブランチにいなければ nil。
  let ref: String?

  /// 書き換えるコミット。
  let target: RawCommit

  /// [target] のあとに続くコミット（親から順）。親を付け替えて作り直す。
  let after: [RawCommit]

  /// 署名されていて書き換えられないコミット（[target] か、あとに続くもの）。なければ nil。
  var signed: RawCommit? { ([target] + after).first { $0.signed } }
}

/// git cat-file で読んだコミットの中身。バイトをそのまま保つため、中身はバイト列で持つ。
struct RawCommit {
  init(_ hash: String, _ text: [UInt8]) {
    self.hash = hash
    self.text = text
  }

  let hash: String
  let text: [UInt8]

  /// 見出しの行（author など）とメッセージの境目。
  private var end: Int { indexOfBytes(text, Array("\n\n".utf8)) ?? text.count }

  private var headers: [ArraySlice<UInt8>] {
    text[..<end].split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
  }

  /// 署名の見出し（gpgsig、SHA-256 のリポジトリでは gpgsig-sha256）があるか。
  var signed: Bool {
    headers.contains { $0.starts(with: "gpgsig ".utf8) || $0.starts(with: "gpgsig-sha256 ".utf8) }
  }

  /// 正規表現 ^author (.*) <([^>]*)> (.*)$ に当たれば、名前・メールアドレス・日時の部分。
  private static func authorLine(_ header: ArraySlice<UInt8>) -> (ArraySlice<UInt8>, ArraySlice<UInt8>, ArraySlice<UInt8>)? {
    let prefix = Array("author ".utf8)
    guard header.starts(with: prefix) else { return nil }
    let body = header.dropFirst(prefix.count)
    let cr = UInt8(ascii: "\r")
    // 名前の「.*」はできるだけ長く取るので、「 <」を後ろから探す。「.」は \r に当たらない。
    var at = body.endIndex - 1
    while at > body.startIndex {
      defer { at -= 1 }
      guard body[at - 1] == UInt8(ascii: " ") && body[at] == UInt8(ascii: "<") else { continue }
      let name = body[body.startIndex..<at - 1]
      if name.contains(cr) {
        continue
      }
      guard let close = body[(at + 1)...].firstIndex(of: UInt8(ascii: ">")),
        close + 1 < body.endIndex, body[close + 1] == UInt8(ascii: " ")
      else { continue }
      let date = body[(close + 2)...]
      if date.contains(cr) {
        continue
      }
      return (name, body[(at + 1)..<close], date)
    }
    return nil
  }

  /// 作者の名前とメールアドレス。
  var author: (String, String) {
    for header in headers {
      if let (name, email, _) = RawCommit.authorLine(header) {
        return (RawCommit.utf8(name), RawCommit.utf8(email))
      }
    }
    return ("", "")
  }

  /// メッセージ（末尾の改行は除く）。
  var message: String { trimRight(RawCommit.utf8(text.count > end + 2 ? text[(end + 2)...] : [])) }

  /// 作者を [name]・[email] に（日時はそのまま）、メッセージを [message]（nil なら元のまま）にした中身。
  /// メッセージを変えるときは UTF-8 で書くので、encoding の見出しは外す。
  func withAuthor(_ name: String, _ email: String, message: String? = nil) -> [UInt8] {
    var lines: [[UInt8]] = []
    for header in headers {
      if let (_, _, date) = RawCommit.authorLine(header) {
        lines.append(Array("author \(name) <\(email)> ".utf8) + date)
      } else if message == nil || !header.starts(with: "encoding ".utf8) {
        lines.append(Array(header))
      }
    }
    let body = message.map { Array("\n\n\(trimRight($0))\n".utf8) } ?? Array(text[end...])
    return Array(lines.joined(separator: [UInt8(ascii: "\n")])) + body
  }

  /// 親を [renamed]（元のハッシュ → 作り直したハッシュ）で付け替えた中身。
  func withParents(_ renamed: [String: String]) -> [UInt8] {
    let prefix = Array("parent ".utf8)
    let lines: [[UInt8]] = headers.map { header in
      guard header.starts(with: prefix) else { return Array(header) }
      let parent = RawCommit.utf8(header.dropFirst(prefix.count))
      return prefix + Array((renamed[parent] ?? parent).utf8)
    }
    return Array(lines.joined(separator: [UInt8(ascii: "\n")])) + text[end...]
  }

  private static func utf8(_ bytes: ArraySlice<UInt8>) -> String { String(decoding: bytes, as: UTF8.self) }
}

/// `git cat-file --batch` の出力を読む。「ハッシュ 種類 バイト数\n中身\n」が続く。
func parseCatFileBatch(_ output: [UInt8]) -> [RawCommit] {
  var commits: [RawCommit] = []
  var at = 0
  while at < output.count {
    guard let lineEnd = output[at...].firstIndex(of: UInt8(ascii: "\n")) else {
      break
    }
    let header = output[at..<lineEnd].split(separator: UInt8(ascii: " "), omittingEmptySubsequences: false)
    guard header.count == 3, header[1].elementsEqual("commit".utf8),
      let size = Int(String(decoding: header[2], as: UTF8.self)),
      lineEnd + 1 + size <= output.count
    else {
      break
    }
    commits.append(RawCommit(String(decoding: header[0], as: UTF8.self), Array(output[(lineEnd + 1)..<(lineEnd + 1 + size)])))
    at = lineEnd + 1 + size + 1
  }
  return commits
}

/// ファイルの履歴の1件。[file] は、そのコミットでのファイル（名前の変更なら元のパスも）。
struct FileCommit {
  init(_ commit: GitCommit, _ file: CommitFile) {
    self.commit = commit
    self.file = file
  }

  let commit: GitCommit
  let file: CommitFile
}

/// `git log --follow -z --name-status --format=%x1e%H%x1f%h%x1f%ad%x1f%an%x1f%s` の出力を読む。
/// コミットごとに「\x1e 見出し \0 \n 変わり方 \0 パス \0」の形。
func parseFileLog(_ output: String) -> [FileCommit] {
  splitOn(output, "\u{1e}").compactMap { record in
    guard let end = indexOf(record, "\0") else { return nil }
    let commits = parseGitLog(slice(record, 0, end))
    guard commits.count == 1, let file = parseNameStatus(slice(record, end + 1)).first else { return nil }
    return FileCommit(commits[0], file)
  }
}

/// コミットで変わったファイル。
struct CommitFile {
  init(_ status: String, _ path: String, from: String? = nil) {
    self.status = status
    self.path = path
    self.from = from
  }

  /// 変わり方の1文字（M 変更・A 追加・D 削除・R 名前の変更・C コピー・T 種類の変更）。
  let status: String
  let path: String

  /// 名前の変更・コピーの元のパス。
  let from: String?
}

/// `git show -z --name-status --format=` の出力を読む。名前の変更・コピーは「R100」のあとに元と新しいパスが続く。
func parseNameStatus(_ output: String) -> [CommitFile] {
  let fields = splitOn(output, "\0")
  var files: [CommitFile] = []
  var i = 0
  while i < fields.count {
    defer { i += 1 }
    let status = trim(fields[i])
    if status.isEmpty || i + 1 >= fields.count {
      continue
    }
    if (starts(status, "R") || starts(status, "C")) && i + 2 < fields.count {
      files.append(CommitFile(unit(status, 0), fields[i + 2], from: fields[i + 1]))
      i += 2
    } else {
      files.append(CommitFile(unit(status, 0), fields[i + 1]))
      i += 1
    }
  }
  return files
}

// Dart の文字列と同じく、符号の並びのまま比べて切る。Swift の String は正準等価で比べ、
// 結合文字（濁点など）を前の文字とまとめて1文字として扱うので、パスや差分の行には使わない。

/// [s] を [separator] の文字（ASCII）で分ける。空の欄も残す（Dart の split と同じ）。
private func splitOn(_ s: String, _ separator: Unicode.Scalar) -> [String] {
  let sep = UInt8(separator.value)
  return s.utf8.split(separator: sep, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
}

/// [s] が [prefix] で始まるか。
private func starts(_ s: String, _ prefix: String) -> Bool { s.utf8.starts(with: prefix.utf8) }

/// [s] が [suffix] で終わるか。
private func ends(_ s: String, _ suffix: String) -> Bool { s.utf8.reversed().starts(with: suffix.utf8.reversed()) }

/// 符号の並びが同じか。
private func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

/// [s] の UTF-8 の [from] バイト目から [to] バイト目の手前まで。区切りは ASCII の文字の前後で使う。
private func slice(_ s: String, _ from: Int, _ to: Int? = nil) -> String {
  let u = s.utf8
  let start = u.index(u.startIndex, offsetBy: from)
  let end = to.map { u.index(u.startIndex, offsetBy: $0) } ?? u.endIndex
  return String(decoding: u[start..<end], as: UTF8.self)
}

/// [s] の UTF-8 の [from] バイト目以降で、[needle] が始まるバイトの位置。
private func indexOf(_ s: String, _ needle: String, from: Int = 0) -> Int? {
  indexOfBytes(Array(s.utf8), Array(needle.utf8), from: from)
}

/// [s] で、[needle] が最後に始まるバイトの位置。
private func lastIndexOf(_ s: String, _ needle: String) -> Int? {
  let bytes = Array(s.utf8)
  let n = Array(needle.utf8)
  var i = bytes.count - n.count
  while i >= 0 {
    if bytes[i..<i + n.count].elementsEqual(n) {
      return i
    }
    i -= 1
  }
  return nil
}

private func indexOfBytes(_ bytes: [UInt8], _ needle: [UInt8], from: Int = 0) -> Int? {
  if needle.isEmpty || bytes.count < needle.count {
    return needle.isEmpty ? min(from, bytes.count) : nil
  }
  var i = from
  while i <= bytes.count - needle.count {
    if bytes[i] == needle[0] && bytes[i..<i + needle.count].elementsEqual(needle) {
      return i
    }
    i += 1
  }
  return nil
}

/// [s] の UTF-8 の [index] バイト目の1文字（ASCII の状態の文字に使う）。
private func unit(_ s: String, _ index: Int) -> String { slice(s, index, index + 1) }

/// 前後の空白を除く（Dart の trim）。
private func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

/// 後ろの空白を除く（Dart の trimRight）。
private func trimRight(_ s: String) -> String {
  var scalars = Substring(s).unicodeScalars
  while let last = scalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
    scalars.removeLast()
  }
  return String(scalars)
}
