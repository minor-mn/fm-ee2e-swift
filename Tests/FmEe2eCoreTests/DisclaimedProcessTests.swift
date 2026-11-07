import Darwin
import Foundation
import Testing

@testable import FmEe2eCore

/// アプリに紐づかない子プロセスとして起動する [runDisclaimed]。
@MainActor
struct DisclaimedProcessTests {
  @Test func runsAndCollectsOutput() async throws {
    let result = try #require(await runDisclaimed("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"]))
    #expect(result.exitCode == 3)
    #expect(result.stdout == "out\n")
    #expect(result.stderr == "err\n")
  }

  /// 起動した子の「責任元」が、このプロセスではなく子自身になっている（macOS がアプリのものとして扱わない）。
  @Test func childIsResponsibleForItself() async throws {
    typealias Responsible = @convention(c) (pid_t) -> pid_t
    let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid"))
    let responsibleFor = unsafeBitCast(symbol, to: Responsible.self)
    // 子は、自分の pid と、自分の責任元の pid を調べられないので、親から調べられるよう少し待つ。
    let file = try makeTempDir("fm-ee2e-disclaim-") + "/pid"
    defer { try? FileManager.default.removeItem(atPath: p.dirname(file)) }
    async let run = runDisclaimed("/bin/sh", ["-c", "echo $$ > \(shQuote(file)); sleep 1"])
    var pid: pid_t?
    for _ in 0..<50 where pid == nil {
      try await Task.sleep(for: .milliseconds(20))
      pid = (try? String(contentsOfFile: file, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    let child = try #require(pid)
    #expect(responsibleFor(child) == child)
    #expect(responsibleFor(child) != responsibleFor(getpid()))
    _ = await run
  }
}
