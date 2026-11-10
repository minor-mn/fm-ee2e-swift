import Foundation
import Testing

@testable import FmEe2eCore

@MainActor
@Suite(.serialized)
struct LegacyGitTests {
  @Test("git --version で 2.31 より古いかを見分ける")
  func version() {
    #expect(isLegacyVersion("git version 1.7.1\n"))
    #expect(isLegacyVersion("git version 2.30.9"))
    #expect(!isLegacyVersion("git version 2.31.0"))
    #expect(!isLegacyVersion("git version 2.39.5 (Apple Git-154)"))
    #expect(!isLegacyVersion("unknown"))
    #expect(isUnsupportedVersion("git version 1.6.6.3"))
    #expect(!isUnsupportedVersion("git version 1.7.0"))
    #expect(!isUnsupportedVersion("git version 1.7.1"))
    #expect(!isUnsupportedVersion("git version 2.39.5 (Apple Git-154)"))
    #expect(!isUnsupportedVersion("unknown"))
  }

  @Test("古い git が「\"\\343...\"」の形で出した名前を戻す")
  func unquote() {
    let files = parseGitDiff(
      """
      diff --git "a/\\346\\227\\245\\346\\234\\254/\\345\\220\\215\\345\\211\\215" "b/\\346\\227\\245\\346\\234\\254/\\345\\220\\215\\345\\211\\215"
      --- "a/\\346\\227\\245\\346\\234\\254/\\345\\220\\215\\345\\211\\215"
      +++ "b/\\346\\227\\245\\346\\234\\254/\\345\\220\\215\\345\\211\\215"
      @@ -1 +1,2 @@
       a
      +b
      """
    )
    #expect(files.map(\.path) == ["日本/名前"])
    #expect(unquoteGitPath("a\\tb\\\"c\\\\") == "a\tb\"c\\")
  }

  @Test("この Mac の git でも、古い git 用のコマンドで一通り動く")
  func localGit() async throws {
    let found = try #require(try await Git.locate())
    let git = LegacyGit(found.executable)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fm-legacy-" + UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    _ = try await runProcess(found.executable, ["init", "-q", root])
    try await exercise(git, root) { path, text in
      try text.write(toFile: p.join(root, path), atomically: true, encoding: .utf8)
    } makeDir: { path in
      try FileManager.default.createDirectory(atPath: p.join(root, path), withIntermediateDirectories: true)
    }
  }

  /// FM_EE2E_LEGACY_GIT_CONTAINER に、古い git の入ったコンテナの名前を入れたときだけ動かす。
  /// コンテナの /tmp に作ったリポジトリで試して、終わったら消す。
  @Test(
    "コンテナの古い git（1.7.1）で一通り動く",
    .enabled(if: ProcessInfo.processInfo.environment["FM_EE2E_LEGACY_GIT_CONTAINER"] != nil)
  )
  func containerGit() async throws {
    let name = ProcessInfo.processInfo.environment["FM_EE2E_LEGACY_GIT_CONTAINER"]!
    let remote = ContainerConnection(name, client: ContainerClient())
    let git = try #require(try await Git.overSsh(remote))
    #expect(git is LegacyGit)
    let root = "/tmp/fm-legacy-" + UUID().uuidString
    try await remote.run("mkdir -p \(shQuote(root)) && cd \(shQuote(root)) && git init -q")
    var failure: Error?
    do {
      try await exercise(git, root) { path, text in
        try await remote.run("printf '%s' \(shQuote(text)) > \(shQuote(p.join(root, path)))")
      } makeDir: { path in
        try await remote.run("mkdir -p \(shQuote(p.join(root, path)))")
      }
    } catch {
      failure = error
    }
    _ = try? await remote.run("rm -rf \(shQuote(root))")
    if let failure { throw failure }
  }

  private func exercise(
    _ git: Git,
    _ root: String,
    write: (String, String) async throws -> Void,
    makeDir: (String) async throws -> Void
  ) async throws {
    func run(_ args: [String]) async throws {
      let result = try await git.run(root, args)
      #expect(result.exitCode == 0, "git \(args): \(result.stderr)")
    }
    try await run(["config", "user.name", "Tester"])
    try await run(["config", "user.email", "tester@example.com"])

    // まだコミットがない。
    var status = try #require(try await git.statusAt(root))
    #expect(status.1.branch == "master" || status.1.branch == "main")
    #expect(try await git.log(root).isEmpty)

    try await makeDir("日本")
    try await write("日本/名前", "a\n")
    try await write("f.txt", "x\n")
    status = try #require(try await git.statusAt(root))
    #expect(status.1.entries.map(\.code).allSatisfy { $0 == "??" })
    #expect(try await git.diffUntracked(root, ["f.txt"]).first?.lines.count == 2)

    try await git.add(root, ["f.txt", "日本"])
    try await git.restoreStaged(root, ["f.txt"])
    status = try #require(try await git.statusAt(root))
    #expect(Set(status.1.entries.map { "\($0.code) \($0.path)" }) == ["A  日本/名前", "?? f.txt"])
    try await git.add(root, ["f.txt"])
    try await git.commit(root, "first")

    try await write("日本/名前", "a\nb\n")
    let diff = try await git.diff(root, ["日本/名前"], staged: false)
    #expect(diff.map(\.path) == ["日本/名前"])
    #expect(diff.first?.added == 1)
    let states = try await git.pathStates(root, ["日本", "f.txt"])
    #expect(states["日本"]?.modified == true)
    #expect(states["f.txt"]?.modified == false)
    try await git.add(root, ["日本/名前"])
    try await git.restoreStaged(root, ["日本/名前"])
    try await git.restore(root, ["日本/名前"])
    #expect(try #require(try await git.statusAt(root)).1.entries.isEmpty)

    try await git.switchBranch(root, "topic", create: true)
    #expect(try #require(try await git.statusAt(root)).1.branch == "topic")
    try await write("f.txt", "x\ny\n")
    try await git.add(root, ["f.txt"])
    try await git.commit(root, "second")
    try await git.renameBranch(root, "topic", "topic2")
    #expect(try await git.localBranches(root).contains("topic2"))

    let log = try await git.log(root)
    #expect(log.map(\.subject) == ["second", "first"])
    #expect(log.allSatisfy { $0.date.count == 16 && $0.shortHash.count >= 7 })
    #expect(try await git.rangeLog(root, log[1].hash, log[0].hash).map(\.subject) == ["second"])
    #expect(try await git.rangeFiles(root, log[1].hash, log[0].hash).map(\.path).sorted() == ["f.txt", "日本/名前"])
    #expect(try await git.commitFiles(root, log[0].hash).map(\.path) == ["f.txt"])
    #expect(try await git.commitDiff(root, log[0].hash).map(\.path) == ["f.txt"])
    let fileLog = try await git.fileLog(root, "f.txt")
    #expect(fileLog.map(\.commit.subject) == ["second", "first"])
    #expect(try await git.fileDiff(root, log[0].hash, fileLog[0].file).first?.added == 1)

    try await git.createTag(root, "v1")
    try await run(["tag", "light", log[1].hash])
    let tags = try await git.tags(root)
    #expect(Set(tags.map { "\($0.name) \($0.commit.subject)" }) == ["v1 second", "light first"])
    #expect(tags.allSatisfy { $0.commit.date.count == 16 && $0.commit.shortHash.count == 7 })
    try await git.deleteTags(root, ["light"])

    let rewrite = try await git.prepareAuthorRewrite(root, log[1].hash)
    #expect(rewrite.after.map(\.hash) == [log[0].hash])
    try await git.rewriteAuthor(root, rewrite, name: "Other", email: "other@example.com")
    #expect(try await git.log(root).map(\.author) == ["Tester", "Other"])

    try await git.switchBranch(root, status.1.branch!)
    #expect(try #require(try await git.statusAt(root)).1.branch == status.1.branch)
  }
}
