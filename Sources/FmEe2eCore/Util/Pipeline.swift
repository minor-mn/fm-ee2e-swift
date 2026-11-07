import Foundation

/// 2つのプロセスを OS のパイプで直結する。大きな転送でもメモリに貯めず、UI を待たせない。
/// 呼んだ Task が取り消されたら（転送の中止など）、両方のプロセスを止める。
nonisolated func runPipeline(
  _ producer: String, _ producerArgs: [String],
  _ consumer: String, _ consumerArgs: [String],
  environment: [String: String] = [:]
) async throws -> ProcResult {
  let running = RunningProcesses()
  return try await withTaskCancellationHandler {
    try await pipeline(producer, producerArgs, consumer, consumerArgs, environment, running)
  } onCancel: {
    running.cancel()
  }
}

/// 動かしているプロセス。取り消されたら、今のものもあとから足すものも止める。
private nonisolated final class RunningProcesses: @unchecked Sendable {
  private let lock = NSLock()
  private var processes: [Process] = []
  private var cancelled = false

  func add(_ process: Process) {
    ChildProcesses.add(process)
    lock.lock()
    processes.append(process)
    let stop = cancelled
    lock.unlock()
    if stop {
      process.terminate()
    }
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let list = processes
    lock.unlock()
    for process in list where process.isRunning {
      process.terminate()
    }
  }
}

private nonisolated func pipeline(
  _ producer: String, _ producerArgs: [String],
  _ consumer: String, _ consumerArgs: [String],
  _ environment: [String: String],
  _ running: RunningProcesses
) async throws -> ProcResult {
  try await Task.detached {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fm-ee2e-pipe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("stderr")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let errors = try FileHandle(forUpdating: log)
    defer { try? errors.close() }
    let pipe = Pipe()
    let source = Process()
    let dest = Process()
    for (process, executable, arguments) in [(source, producer, producerArgs), (dest, consumer, consumerArgs)] {
      process.executableURL = URL(fileURLWithPath: resolveExecutable(executable))
      process.arguments = arguments
      process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
      process.standardError = errors
    }
    source.standardInput = FileHandle.nullDevice
    source.standardOutput = pipe
    dest.standardInput = pipe
    dest.standardOutput = FileHandle.nullDevice
    try dest.run()
    running.add(dest)
    do {
      try source.run()
      running.add(source)
    } catch {
      try? pipe.fileHandleForWriting.close()
      dest.terminate()
      dest.waitUntilExit()
      ChildProcesses.remove(dest.processIdentifier)
      throw error
    }
    try? pipe.fileHandleForReading.close()
    try? pipe.fileHandleForWriting.close()
    source.waitUntilExit()
    dest.waitUntilExit()
    ChildProcesses.remove(source.processIdentifier)
    ChildProcesses.remove(dest.processIdentifier)
    try errors.seek(toOffset: 0)
    let stderr = try errors.readToEnd() ?? Data()
    let failed = source.terminationStatus != 0 ? source : dest
    let code = failed.terminationReason == .uncaughtSignal ? -Int(failed.terminationStatus) : Int(failed.terminationStatus)
    return ProcResult(exitCode: code, stdoutData: Data(), stderrData: stderr)
  }.value
}
