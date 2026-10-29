import Foundation
import Testing

@testable import FmEe2eCore

/// 一時的なリポジトリのフォルダー。
private func tempRepo() throws -> String {
  var template = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("fm-ee2e-git-XXXXXX").utf8CString)
  guard mkdtemp(&template) != nil else {
    throw AppError("一時フォルダーを作れません")
  }
  return String(cString: template)
}

private func write(_ path: String, _ text: String) throws {
  try text.write(toFile: path, atomically: false, encoding: .utf8)
}

private func mkdir(_ path: String) throws {
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
}

/// シンボリックリンクをたどった絶対パス。
private func resolve(_ path: String) -> String {
  guard let resolved = realpath(path, nil) else { return path }
  defer { free(resolved) }
  return String(cString: resolved)
}

private func trimmed(_ result: ProcResult) -> String { result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }

@Suite(.serialized)
struct GitTests {
  @Test("ファイルの履歴は名前の変更もたどり、コミットごとの名前で差分を読める") func fileLogFollowsRenames() async throws {
    let repo = try tempRepo()
    defer { try? FileManager.default.removeItem(atPath: repo) }
    func git(_ args: [String]) async throws {
      let result = try await runProcess(
        "git",
        ["-c", "user.name=e2e", "-c", "user.email=e2e@example.com"] + args,
        workingDirectory: repo
      )
      #expect(result.exitCode == 0, "\(result.stderr)")
    }

    try await git(["init", "-b", "main"])
    try mkdir(p.join(repo, "sub"))
    try write(p.join(repo, "old*.txt"), "one\ntwo\nthree\nfour\n")
    try write(p.join(repo, "other.txt"), "other")
    try await git(["add", "."])
    try await git(["commit", "-m", "first"])
    try await git(["mv", "old*.txt", "sub/new name.txt"])
    try await git(["commit", "-m", "rename"])
    try write(p.join(repo, "sub", "new name.txt"), "one\ntwo\nthree\nfive\n")
    try write(p.join(repo, "other.txt"), "changed")
    try await git(["commit", "-am", "edit"])

    let g = try #require(try await Git.locate())
    // フォルダーからの相対パスでたどれる。
    let commits = try await g.fileLog(p.join(repo, "sub"), "new name.txt")
    #expect(
      commits.map { "\($0.commit.subject)|\($0.file.status)|\($0.file.from ?? "nil")|\($0.file.path)" } == [
        "edit|M|nil|sub/new name.txt",
        "rename|R|old*.txt|sub/new name.txt",
        "first|A|nil|old*.txt",
      ]
    )
    try #require(commits.count == 3)

    let edit = try await g.fileDiff(repo, commits[0].commit.hash, commits[0].file)
    #expect(edit.map(\.path) == ["sub/new name.txt"])
    #expect(edit.first?.lines.filter { $0.kind == .added }.map(\.text) == ["five"])
    let rename = try await g.fileDiff(repo, commits[1].commit.hash, commits[1].file)
    #expect(rename.map { "\($0.from ?? "nil")|\($0.path)" } == ["old*.txt|sub/new name.txt"])
    let first = try await g.fileDiff(repo, commits[2].commit.hash, commits[2].file)
    #expect(first.map { "\($0.path)|\($0.added)" } == ["old*.txt|4"])

    // 範囲の差分。最初のコミットからなら、空の状態からの差分。
    let all = try await g.rangeFiles(repo, commits[2].commit.hash, commits[0].commit.hash)
    #expect(all.map { "\($0.status)|\($0.path)" } == ["A|other.txt", "A|sub/new name.txt"])
    let renameToEdit = try await g.rangeFiles(repo, commits[1].commit.hash, commits[0].commit.hash)
    #expect(
      renameToEdit.map { "\($0.status)|\($0.from ?? "nil")|\($0.path)" } == [
        "M|nil|other.txt", "R|old*.txt|sub/new name.txt",
      ]
    )
    // 両端の名前を渡すと、そのファイルだけを名前の変更として出す。
    let fileRange = try await g.rangeDiff(
      repo,
      commits[1].commit.hash,
      commits[0].commit.hash,
      paths: ["old*.txt", "sub/new name.txt"]
    )
    #expect(fileRange.map { "\($0.from ?? "nil")|\($0.path)|\($0.added)" } == ["old*.txt|sub/new name.txt|1"])
  }

  @Test("コミットの作者とメッセージを書き換え、あとのコミット（マージを含む）は中身とコミッターを変えずに作り直す") func rewriteAuthor() async throws {
    let repo = try tempRepo()
    defer { try? FileManager.default.removeItem(atPath: repo) }
    @discardableResult
    func git(_ args: [String], committer: String = "e2e") async throws -> String {
      let result = try await runProcess(
        "git",
        ["-c", "user.name=e2e", "-c", "user.email=e2e@example.com"] + args,
        workingDirectory: repo,
        environment: ["GIT_COMMITTER_NAME": committer]
      )
      #expect(result.exitCode == 0, "\(result.stderr)")
      return trimmed(result)
    }

    func commit(_ file: String, _ message: String) async throws {
      try write(p.join(repo, file), message)
      try await git(["add", file])
      try await git(["commit", "-m", message])
    }

    try await git(["init", "-b", "main"])
    try await commit("a.txt", "first")
    try await commit("b.txt", "second")
    try await git(["switch", "-c", "topic"])
    try await commit("c.txt", "topic")
    try await git(["switch", "main"])
    try await commit("d.txt", "main")
    try await git(["merge", "--no-ff", "-m", "merge topic", "topic"], committer: "merger")
    // コミットしていない変更は、そのまま残る。
    try write(p.join(repo, "a.txt"), "dirty")
    let second = try await git(["rev-parse", "HEAD~1~1"])
    #expect(try await git(["log", "-1", "--format=%s", second]) == "second")
    let treesBefore = try await git(["log", "--format=%T %P", "HEAD"])

    let g = try #require(try await Git.locate())
    let rewrite = try await g.prepareAuthorRewrite(repo, second)
    #expect(rewrite.signed == nil)
    #expect(rewrite.target.author == ("e2e", "e2e@example.com"))
    #expect(rewrite.target.message == "second")
    #expect(rewrite.after.count == 3)
    try await g.rewriteAuthor(repo, rewrite, name: "山田 花子", email: "hanako@example.com", message: "二番目\n\n本文")

    #expect(
      try await git(["log", "--format=%an|%ae|%cn|%s", "main"])
        == [
          "e2e|e2e@example.com|merger|merge topic",
          "e2e|e2e@example.com|e2e|main",
          "e2e|e2e@example.com|e2e|topic",
          "山田 花子|hanako@example.com|e2e|二番目",
          "e2e|e2e@example.com|e2e|first",
        ].joined(separator: "\n")
    )
    #expect(try await git(["log", "-1", "--format=%B", "main~1~1"]) == "二番目\n\n本文")
    // 中身（ツリー）は同じで、マージはマージのまま。
    let treesAfter = try await git(["log", "--format=%T %P", "HEAD"])
    let before = treesBefore.components(separatedBy: "\n").map { $0.components(separatedBy: " ") }
    let after = treesAfter.components(separatedBy: "\n").map { $0.components(separatedBy: " ") }
    #expect(after.map(\.count) == before.map(\.count))
    #expect(after.map { $0[0] } == before.map { $0[0] })
    #expect(try String(contentsOfFile: p.join(repo, "a.txt"), encoding: .utf8) == "dirty")
    // （出力の前後の空白は除いている）
    #expect(try await git(["status", "--porcelain"]) == "M a.txt")

    // 一番新しいコミットも書き換えられる。メッセージを変えなければ元のまま。
    let head = try await g.prepareAuthorRewrite(repo, try await git(["rev-parse", "HEAD"]))
    #expect(head.after.isEmpty)
    try await g.rewriteAuthor(repo, head, name: "x", email: "x@example.com")
    #expect(try await git(["log", "-1", "--format=%an|%ae|%s", "main"]) == "x|x@example.com|merge topic")
  }

  @Test("署名されたコミットと、署名されたコミットが後に続くコミットは書き換えられない") func signedCommits() async throws {
    let repo = try tempRepo()
    defer { try? FileManager.default.removeItem(atPath: repo) }
    @discardableResult
    func git(_ args: [String], input: String? = nil) async throws -> String {
      let result = try await runProcess(
        "git",
        ["-c", "user.name=e2e", "-c", "user.email=e2e@example.com"] + args,
        workingDirectory: repo,
        input: input.map { Data($0.utf8) }
      )
      #expect(result.exitCode == 0)
      return trimmed(result)
    }

    try await git(["init", "-b", "main"])
    try await git(["commit", "--allow-empty", "-m", "first"])
    let first = try await git(["rev-parse", "HEAD"])
    let tree = try await git(["rev-parse", "HEAD^{tree}"])
    // 署名の見出しだけを付けたコミットを作る（中身の正しさは見ない）。
    let signed = try await git(
      ["hash-object", "-t", "commit", "-w", "--stdin"],
      input:
        "tree \(tree)\nparent \(first)\nauthor e2e <e2e@example.com> 0 +0000\ncommitter e2e <e2e@example.com> 0 +0000\n"
        + "gpgsig -----BEGIN SSH SIGNATURE-----\n xxx\n -----END SSH SIGNATURE-----\n\nsigned\n"
    )
    try await git(["update-ref", "refs/heads/main", signed])

    let g = try #require(try await Git.locate())
    #expect(try await g.prepareAuthorRewrite(repo, signed).signed?.hash == signed)
    #expect(try await g.prepareAuthorRewrite(repo, first).signed?.hash == signed)
  }

  @Test("git の設定から、紐付け先・push 先・リポジトリ名・ユーザーを決める") func repositoryInfoFromConfig() {
    let config = parseGitConfig(
      "user.name\n山田 花子\0user.email\nhanako@example.com\0core.bare\nfalse\0"
        + "remote.origin.url\ngit@github.com:owner/name.git\0remote.pushdefault\norigin\0"
        + "branch.Feature/X.remote\norigin\0branch.Feature/X.pushremote\nfork\0novalue\0"
    )
    #expect(config["novalue"] == "")
    #expect(
      repositoryInfo(config, "Feature/X")
        == (remote: "origin", pushRemote: "fork", repository: "owner/name", user: "山田 花子 <hanako@example.com>")
    )
    // 紐付けがなければ (no upstream)。リモートの設定が remote.pushdefault だけなら (no remote)。
    #expect(
      repositoryInfo(config, "main")
        == (
          remote: "(no upstream)", pushRemote: "<no branch.pushRemote>", repository: nil,
          user: "山田 花子 <hanako@example.com>"
        )
    )
    #expect(
      repositoryInfo(parseGitConfig("remote.pushdefault\norigin\0user.email\na@example.com\0"), "main")
        == (remote: "(no remote)", pushRemote: "<no branch.pushRemote>", repository: nil, user: "<a@example.com>")
    )
    #expect(
      repositoryInfo(config, "HEAD") == (remote: nil, pushRemote: nil, repository: nil, user: "山田 花子 <hanako@example.com>")
    )
  }

  @Test("サブフォルダーからでも、一番上のフォルダーと一番上からのパスの git status を読む") func statusFromSubfolder() async throws {
    let repo = try tempRepo()
    defer { try? FileManager.default.removeItem(atPath: repo) }
    func git(_ args: [String]) async throws {
      let result = try await runProcess("git", args, workingDirectory: repo)
      #expect(result.exitCode == 0, "\(result.stderr)")
    }

    try await git(["init", "-b", "main"])
    try await git(["remote", "add", "origin", "https://github.com/owner/name.git"])
    try await git(["config", "branch.main.remote", "origin"])
    try mkdir(p.join(repo, "sub"))
    try write(p.join(repo, "top.txt"), "x")
    try write(p.join(repo, "sub", "a.txt"), "x")

    let g = try #require(try await Git.locate())
    let (root, status) = try #require(try await g.statusAt(p.join(repo, "sub")))
    #expect(resolve(root) == resolve(repo))
    #expect(status.branch == "main")
    #expect(status.remote == "origin")
    #expect(status.repository == "owner/name")
    #expect(status.entries.map(\.path).sorted() == ["sub/", "top.txt"])
    #expect(try await g.statusAt(NSTemporaryDirectory()) == nil)
  }
}
