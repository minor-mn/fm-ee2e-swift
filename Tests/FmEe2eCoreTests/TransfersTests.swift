import Foundation
import Testing

@testable import FmEe2eCore

@MainActor
struct TransfersTests {
  /// [condition] が成り立つまで待つ（最大で約5秒）。
  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<500 where !condition() {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func isDone(_ item: TransferItem) -> Bool { if case .done = item.state { true } else { false } }
  private func isCancelled(_ item: TransferItem) -> Bool { if case .cancelled = item.state { true } else { false } }

  @Test func runsItemsOneByOneInOrder() async {
    let transfers = Transfers()
    var log: [String] = []
    var finished: [String] = []
    transfers.onJobFinished = { finished.append($0.title) }
    let first = TransferJob("1", [TransferItem("a") { log.append("a") }, TransferItem("b") { log.append("b") }]) { _ in log.append("finish1") }
    let second = TransferJob("2", [TransferItem("c") { log.append("c") }])
    transfers.add(first)
    transfers.add(second)
    await waitUntil { finished.count == 2 }
    #expect(log == ["a", "b", "finish1", "c"])
    #expect(finished == ["1", "2"])
    #expect(first.items.allSatisfy(isDone) && second.items.allSatisfy(isDone))
    #expect(!transfers.busy)
  }

  @Test func failureKeepsReasonAndContinues() async {
    let transfers = Transfers()
    var finished = false
    transfers.onJobFinished = { _ in finished = true }
    let job = TransferJob("job", [TransferItem("bad") { throw AppError("こわれた") }, TransferItem("good") {}])
    transfers.add(job)
    await waitUntil { finished }
    if case .failed(let reason) = job.items[0].state {
      #expect(reason == "こわれた")
    } else {
      Issue.record("not failed: \(job.items[0].state)")
    }
    #expect(isDone(job.items[1]))
    #expect(job.failedCount == 1 && job.doneCount == 1)
    #expect(!job.groupDone(0))
  }

  @Test func cancelsRunningAndWaitingItems() async {
    let transfers = Transfers()
    var finished = false
    var ranLast = false
    transfers.onJobFinished = { _ in finished = true }
    let job = TransferJob(
      "job",
      [
        TransferItem("slow") { try await Task.sleep(nanoseconds: 10_000_000_000) },
        TransferItem("last") { ranLast = true },
      ])
    transfers.add(job)
    await waitUntil { if case .running = job.items[0].state { true } else { false } }
    transfers.cancel(job)
    await waitUntil { finished }
    #expect(isCancelled(job.items[0]) && isCancelled(job.items[1]))
    #expect(!ranLast)
  }

  @Test func cancelsOnlyOneWaitingItem() async {
    let transfers = Transfers()
    var finished = false
    var ran: [String] = []
    transfers.onJobFinished = { _ in finished = true }
    let job = TransferJob(
      "job",
      [
        TransferItem("a") { try await Task.sleep(nanoseconds: 50_000_000); ran.append("a") },
        TransferItem("b") { ran.append("b") },
        TransferItem("c") { ran.append("c") },
      ])
    transfers.add(job)
    transfers.cancel(job.items[1])
    await waitUntil { finished }
    #expect(ran == ["a", "c"])
    #expect(isCancelled(job.items[1]))
  }

  @Test func retryRunsFailedItemsAgainAfterWaitingOnes() async {
    let transfers = Transfers()
    var finished: [String] = []
    var log: [String] = []
    var attempts = 0
    transfers.onJobFinished = { finished.append($0.title) }
    let first = TransferJob(
      "1",
      [
        TransferItem("flaky") {
          attempts += 1
          log.append("flaky\(attempts)")
          if attempts == 1 {
            throw AppError("失敗")
          }
        }
      ])
    transfers.add(first)
    await waitUntil { finished == ["1"] }
    #expect(first.items[0].retryable)
    // 2つ目の転送が待っている間にやり直すと、その後ろに入る。
    let second = TransferJob("2", [TransferItem("slow") { try await Task.sleep(nanoseconds: 50_000_000); log.append("slow") }])
    transfers.add(second)
    transfers.retry(first.items)
    await waitUntil { finished.count == 3 }
    #expect(log == ["flaky1", "slow", "flaky2"])
    #expect(finished == ["1", "2", "1"])
    #expect(isDone(first.items[0]) && !first.items[0].retryable)
  }

  @Test func cancellingStopsProcess() async throws {
    let started = Date()
    let task = Task { try await runProcess("/bin/sleep", ["10"]) }
    try await Task.sleep(nanoseconds: 100_000_000)
    task.cancel()
    let result = try await task.value
    #expect(result.exitCode == -Int(SIGTERM))
    #expect(Date().timeIntervalSince(started) < 5)
  }

  @Test func cancellingStopsPipeline() async throws {
    let started = Date()
    let task = Task { try await runPipeline("/bin/sleep", ["10"], "/bin/cat", []) }
    try await Task.sleep(nanoseconds: 100_000_000)
    task.cancel()
    _ = try await task.value
    #expect(Date().timeIntervalSince(started) < 5)
  }
}
