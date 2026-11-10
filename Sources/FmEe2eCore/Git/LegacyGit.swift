import Foundation

/// git 2.31 より古い git（git 1.7.1 まで）。[Git] が使うオプションやコマンドのうち、古い git にないものを置き換える。
/// - git -C がない（1.8.5 から）: [dir] へ移ってから実行する。
/// - --literal-pathspecs（1.8.5 から）・git -c（1.7.2 から）がない: 付けない（パスの「*」はワイルドカードになり、
///   日本語などの名前は「"\343..."」の形で出るので、読むときに戻す）。
/// - git status --branch（1.7.2 から）がない: ブランチは git symbolic-ref で読む。
/// - git restore・git switch（2.23 から）がない: git checkout・git reset を使う。
/// - --date=format:（2.6 から）がない: --date=iso の先頭を使う。
/// - git log -z に --format を付けると、コミットの間が NUL ではなく改行になる: 書式の末尾に %x00 を足す。
/// - --diff-merges（2.31 から）がない: git show は -m --first-parent を使う。
/// - for-each-ref の %(if)（2.13 から）がない。merge-base --is-ancestor（1.8.0 から）・rev-list --ancestry-path（1.7.2 から）がない。
final class LegacyGit: Git {
  override func commandLine(in dir: String, _ args: [String], tty: Bool = false) throws -> (String, [String]) {
    if let remote = ssh {
      return (remote.executionPath, try remote.gitArgs(args, dir: dir, tty: tty))
    }
    // sh -c の $0 が [dir]、$@ が git と引数。
    return ("/bin/sh", ["-c", "cd -- \"$0\" && exec \"$@\"", dir, executable] + args)
  }

  override var literalPathspecs: [String] { [] }
  override var rawPathNames: [String] { [] }
  override var dateOption: String { "--date=iso" }
  override var noHeader: String { "--pretty=format:" }
  override var recordEnd: String { "%x00" }
  override var firstParentDiff: [String] { ["-m", "--first-parent"] }

  /// git log --follow に -m --first-parent を付けると、たどる履歴が1つ目の親だけになるので付けない
  /// （マージのコミットは --name-status で何も出ないので、一覧に出ない）。
  override var followFirstParent: [String] { [] }

  /// git status --porcelain -z の前に、git symbolic-ref で読んだブランチ名を「## 名前」の項目として足す。
  override func status(_ dir: String) async throws -> ProcResult {
    async let statusRun = run(dir, ["status", "--porcelain", "-z"])
    async let refRun = run(dir, ["symbolic-ref", "-q", "HEAD"])
    let (status, ref) = try await (statusRun, refRun)
    if status.exitCode != 0 {
      return status
    }
    let name = Git.decode(ref.stdoutData).trimmingCharacters(in: .whitespacesAndNewlines)
    let branch = ref.exitCode == 0 && name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : "HEAD (no branch)"
    return ProcResult(exitCode: 0, stdoutData: Data("## \(branch)\0".utf8) + status.stdoutData, stderrData: status.stderrData)
  }

  override func restore(_ root: String, _ paths: [String]) async throws { try await change(root, ["checkout", "--"] + paths) }

  override func restoreStaged(_ root: String, _ paths: [String]) async throws {
    let head = try await run(root, ["rev-parse", "--verify", "--quiet", "HEAD"])
    try await change(
      root,
      head.exitCode == 0
        ? ["reset", "-q", "--"] + paths
        : ["rm", "--cached", "-r", "--quiet", "--"] + paths
    )
  }

  /// 最後の「--」で、[name] をファイルではなくブランチとして扱わせる。
  override func switchBranch(_ root: String, _ name: String, track: String? = nil, create: Bool = false) async throws {
    let target: [String] =
      if let track { ["-b", name, "--track", track] } else if create { ["-b", name] } else { [name] }
    let result = try await run(root, ["checkout"] + target + ["--"])
    if result.exitCode != 0 {
      throw failure(["checkout"], result)
    }
  }

  /// 注釈付きタグの先のコミット（%(*…)）と、タグがそのまま指すもの（%(…)）の両方を読み、
  /// %(*objectname) があれば前者を使う。短いハッシュは %(objectname:short) がないので先頭7文字。
  override func tags(_ root: String) async throws -> [GitTag] {
    let fields = ["objectname", "authordate:iso", "authorname", "subject"]
    let format = "%(refname:short)%1f" + fields.flatMap { ["%(\($0))", "%(*\($0))"] }.joined(separator: "%1f") + "%00"
    let result = try await run(root, ["for-each-ref", "--sort=-creatordate", "--format=\(format)", "refs/tags/"])
    if result.exitCode != 0 {
      throw failure(["for-each-ref"], result)
    }
    return Git.decode(result.stdoutData).components(separatedBy: "\0").compactMap { record in
      let f = record.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1f}")
      guard f.count == 9 else { return nil }
      let annotated = !f[2].isEmpty
      func pick(_ i: Int) -> String { annotated ? f[i + 1] : f[i] }
      let hash = pick(1)
      return GitTag(
        name: f[0],
        commit: GitCommit(hash, String(hash.prefix(7)), String(pick(3).prefix(16)), pick(5), pick(7))
      )
    }
  }

  /// git rev-list --parents で [hash]..HEAD を親から順に読み、親のどれかが [hash] かその子孫なら子孫とする。
  override func descendants(_ root: String, _ hash: String) async throws -> [String] {
    let listed = try await output(root, ["rev-list", "--topo-order", "--reverse", "--parents", "\(hash)..HEAD"])
    var reached: Set<String> = [hash]
    var result: [String] = []
    for line in listed.components(separatedBy: "\n") {
      let ids = line.split(separator: " ").map(String.init)
      guard let id = ids.first else { continue }
      if ids.dropFirst().contains(where: reached.contains) {
        reached.insert(id)
        result.append(id)
      }
    }
    return result
  }

  /// git merge-base [hash] HEAD が [hash] そのものなら、HEAD の履歴にある。
  override func isAncestor(_ root: String, _ hash: String) async throws -> Bool {
    let full = try await run(root, ["rev-parse", "--verify", "--quiet", hash])
    let base = try await run(root, ["merge-base", hash, "HEAD"])
    let trimmed = { (r: ProcResult) in Git.decode(r.stdoutData).trimmingCharacters(in: .whitespacesAndNewlines) }
    return full.exitCode == 0 && base.exitCode == 0 && trimmed(full) == trimmed(base)
  }
}

/// git --version の出力（「git version 1.7.1」「git version 2.39.5 (Apple Git-154)」など）が 2.31 より古いか。
/// 読めなければ古くないものとする。
func isLegacyVersion(_ output: String) -> Bool { gitVersion(output).map { $0 < (2, 31) } ?? false }

/// git --version の出力が 1.7.0 より古いか（git status --porcelain がなく、使えない）。読めなければ古くないものとする。
func isUnsupportedVersion(_ output: String) -> Bool { gitVersion(output).map { $0 < (1, 7) } ?? false }

/// git --version の出力の、メジャーとマイナーの番号。読めなければ nil。
private func gitVersion(_ output: String) -> (Int, Int)? {
  guard let range = output.range(of: "git version ") else { return nil }
  let numbers = output[range.upperBound...].prefix { $0.isNumber || $0 == "." }.split(separator: ".").compactMap { Int($0) }
  return numbers.count >= 2 ? (numbers[0], numbers[1]) : nil
}
