import Darwin
import Foundation
import Testing

@testable import FmEe2eCore

/// アプリの終了時に止める子プロセスを、起動から終了まで正しく覚えているか。
/// terminateAll はほかのテストのプロセスまで止めてしまうので、ここでは呼ばない。
@MainActor
struct ChildProcessesTests {
  @Test func remembersRunningProcessUntilItEnds() async throws {
    let process = try RunningProcess("/bin/sleep", ["30"])
    let pid = process.pid
    #expect(ChildProcesses.running.contains(pid))
    process.kill()
    #expect(await process.exitCode == -Int(SIGTERM))
    await process.waitForOutput()
    #expect(!ChildProcesses.running.contains(pid))
  }

  @Test func forgetsProcessThatEndsImmediately() async throws {
    let process = try RunningProcess("/usr/bin/true", [])
    let pid = process.pid
    #expect(await process.exitCode == 0)
    #expect(!ChildProcesses.running.contains(pid))
  }

  @Test func forgetsPipelineProcessesWhenDone() async throws {
    let before = ChildProcesses.running
    let result = try await runPipeline("/bin/echo", ["hello"], "/bin/cat", [])
    #expect(result.exitCode == 0)
    // 並んで動くほかのテストの子プロセスは増えていてよい。このパイプラインのものだけが残っていなければよい。
    let added = ChildProcesses.running.subtracting(before)
    for pid in added {
      #expect(Darwin.kill(pid, 0) == 0, "終わった子プロセス \(pid) が残っている")
    }
  }
}
