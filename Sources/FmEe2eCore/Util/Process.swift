import Darwin
import Foundation

/// 文言だけのエラー。
struct AppError: Error, CustomStringConvertible {
  init(_ message: String) {
    self.message = message
  }

  let message: String

  var description: String { message }
}

/// 外部コマンドの失敗。メッセージは標準エラー出力。
struct CommandFailed: Error, CustomStringConvertible {
  init(_ message: String) {
    self.message = message
  }

  let message: String

  var description: String { message }
}

/// 外部コマンドを実行できなかったときのエラー。
struct ProcessError: Error, CustomStringConvertible {
  init(_ executable: String, _ arguments: [String], _ message: String, _ errorCode: Int = 0) {
    self.executable = executable
    self.arguments = arguments
    self.message = message
    self.errorCode = errorCode
  }

  let executable: String
  let arguments: [String]
  let message: String
  let errorCode: Int

  var description: String { message.isEmpty ? tr("process.failed", ["command": "\(executable) \(arguments.joined(separator: " "))"]) : message }
}

/// 利用者に見せるエラーの文言。
func errorMessage(_ error: any Error) -> String {
  let ns = error as NSError
  if [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, NSURLErrorDomain].contains(ns.domain) {
    return ns.localizedDescription
  }
  return String(describing: error)
}

/// シグナルで終わった場合（負の値で表す）は、シェルと同じく 128+シグナル番号で表す。
nonisolated func shellStatus(_ exitCode: Int) -> Int { exitCode < 0 ? 128 - exitCode : exitCode }

/// 端末に出す終了コード。
nonisolated func exitStatusText(_ exitCode: Int) -> String { tr("process.exit_status", ["code": shellStatus(exitCode)]) }

/// 外部コマンドの結果。
nonisolated struct ProcResult: Sendable {
  /// シグナルで終わったときは、負のシグナル番号。
  let exitCode: Int
  let stdoutData: Data
  let stderrData: Data

  /// UTF-8 として読む（不正なバイトは置き換える）。
  var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
  var stderr: String { String(decoding: stderrData, as: UTF8.self) }
}

/// 実行ファイルを探す。「/」を含まなければ PATH から探す。
nonisolated func resolveExecutable(_ name: String) -> String {
  if name.contains("/") {
    return name
  }
  let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
  for dir in path.split(separator: ":") {
    let candidate = "\(dir)/\(name)"
    if access(candidate, X_OK) == 0 {
      return candidate
    }
  }
  return name
}

/// このアプリが起動して、まだ終わっていない子プロセス。アプリを終了するときにまとめて止める
/// （止めないと、圧縮の tar などが親のいないまま動き続ける）。
nonisolated enum ChildProcesses {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var pids = Set<Int32>()

  /// 起動した [process] を覚える。もう終わっていれば覚えない（終わったときの [remove] が先に済んでいることがある）。
  static func add(_ process: Process) {
    let pid = process.processIdentifier
    add(pid)
    if !process.isRunning {
      remove(pid)
    }
  }

  /// 自分で waitpid する子プロセス（[runDisclaimed]）。待ち終えたら [remove] する。
  static func add(_ pid: Int32) {
    lock.withLock { _ = pids.insert(pid) }
  }

  static func remove(_ pid: Int32) {
    lock.withLock { _ = pids.remove(pid) }
  }

  /// まだ終わっていない子プロセスの pid。
  static var running: Set<Int32> { lock.withLock { pids } }

  /// 残っている子プロセスに SIGTERM を送る。
  static func terminateAll() {
    for pid in running {
      Darwin.kill(pid, SIGTERM)
    }
  }
}

/// 実行中の外部コマンド。
/// 標準出力・標準エラー出力は [onStdout]・[onStderr] に、読めた順にメインスレッドで渡す。
final class RunningProcess {
  /// [environment] は今の環境変数に足す。
  init(
    _ executable: String,
    _ arguments: [String],
    workingDirectory: String? = nil,
    environment: [String: String]? = nil
  ) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: resolveExecutable(executable))
    process.arguments = arguments
    if let workingDirectory {
      process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
    }
    if let environment {
      process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    }
    self.process = process
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    // 終わった子プロセスの標準入力に書いても、SIGPIPE でこのアプリが落ちないようにする。
    _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    self.stdinPipe = stdinPipe
    self.stdoutPipe = stdoutPipe
    self.stderrPipe = stderrPipe
    process.terminationHandler = { [weak self] p in
      ChildProcesses.remove(p.processIdentifier)
      let code = p.terminationReason == .uncaughtSignal ? -Int(p.terminationStatus) : Int(p.terminationStatus)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self else { return }
          self.exitCodeValue = code
          for waiter in self.exitWaiters {
            waiter.resume(returning: code)
          }
          self.exitWaiters.removeAll()
        }
      }
    }
    do {
      try process.run()
    } catch {
      throw ProcessError(executable, arguments, tr("process.cannot_run", ["executable": executable, "error": error.localizedDescription]), -1)
    }
    ChildProcesses.add(process)
    startReading()
  }

  private let process: Process
  private let stdinPipe: Pipe?
  private let stdoutPipe: Pipe?
  private let stderrPipe: Pipe?
  private var exitCodeValue: Int?
  private var exitWaiters: [CheckedContinuation<Int, Never>] = []
  private var outputDone = 0
  private var outputWaiters: [CheckedContinuation<Void, Never>] = []

  /// 読めた標準出力。
  var onStdout: ((Data) -> Void)?

  /// 読めた標準エラー出力。
  var onStderr: ((Data) -> Void)?

  var pid: Int32 { process.processIdentifier }

  private func startReading() {
    for (pipe, isStdout) in [(stdoutPipe, true), (stderrPipe, false)] {
      guard let pipe else {
        outputDone += 1
        continue
      }
      let handle = pipe.fileHandleForReading
      // 別のスレッドで読み、メインスレッドへ渡す。
      Thread.detachNewThread { [weak self] in
        while true {
          let data = handle.availableData
          let chunk = data
          DispatchQueue.main.sync {
            MainActor.assumeIsolated {
              guard let self else { return }
              if chunk.isEmpty {
                self.outputDone += 1
                if self.outputDone == 2 {
                  for waiter in self.outputWaiters {
                    waiter.resume()
                  }
                  self.outputWaiters.removeAll()
                }
              } else if isStdout {
                self.onStdout?(chunk)
              } else {
                self.onStderr?(chunk)
              }
            }
          }
          if data.isEmpty {
            break
          }
        }
      }
    }
  }

  /// 標準出力・標準エラー出力を読み終えるまで待つ。
  func waitForOutput() async {
    if outputDone >= 2 {
      return
    }
    await withCheckedContinuation { outputWaiters.append($0) }
  }

  /// 終了コード。シグナルで終わったときは負のシグナル番号。
  var exitCode: Int {
    get async {
      if let exitCodeValue {
        return exitCodeValue
      }
      return await withCheckedContinuation { exitWaiters.append($0) }
    }
  }

  var isRunning: Bool { process.isRunning }

  func write(_ data: Data) {
    guard let handle = stdinPipe?.fileHandleForWriting else { return }
    try? handle.write(contentsOf: data)
  }

  func write(_ text: String) {
    write(Data(text.utf8))
  }

  func closeStdin() {
    try? stdinPipe?.fileHandleForWriting.close()
  }

  func kill(_ signal: Int32 = SIGTERM) {
    if process.isRunning {
      Darwin.kill(process.processIdentifier, signal)
    }
  }
}

/// [runProcess] と同じく実行して終わるまで待ち、標準エラー出力を1行読めるたびに [onStderrLine] に（メインスレッドで）渡す
/// （tar -v の進み具合を出すときなど）。呼んだ Task が取り消されたら、コマンドを止める。
@discardableResult
func runProcess(
  _ executable: String,
  _ arguments: [String],
  environment: [String: String]? = nil,
  onStderrLine: @escaping (String) -> Void
) async throws -> ProcResult {
  let process = try RunningProcess(executable, arguments, environment: environment)
  var out = Data()
  var err = Data()
  var pending = Data()
  process.onStdout = { out.append($0) }
  process.onStderr = { chunk in
    err.append(chunk)
    pending.append(chunk)
    while let newline = pending.firstIndex(of: 0x0a) {
      let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
      pending.removeSubrange(pending.startIndex...newline)
      onStderrLine(line)
    }
  }
  process.closeStdin()
  let pid = process.pid
  let code = await withTaskCancellationHandler {
    await process.exitCode
  } onCancel: {
    Darwin.kill(pid, SIGTERM)
  }
  await process.waitForOutput()
  return ProcResult(exitCode: code, stdoutData: out, stderrData: err)
}

/// 外部コマンドを実行して、終わるまで待つ。
/// 起動できなければ [ProcessError] を投げる。[input] は標準入力に書いて閉じる。
@discardableResult
func runProcess(
  _ executable: String,
  _ arguments: [String],
  workingDirectory: String? = nil,
  environment: [String: String]? = nil,
  input: Data? = nil
) async throws -> ProcResult {
  let process = try RunningProcess(executable, arguments, workingDirectory: workingDirectory, environment: environment)
  var out = Data()
  var err = Data()
  process.onStdout = { out.append($0) }
  process.onStderr = { err.append($0) }
  if let input {
    // 大きな入力でも詰まらないよう、別のスレッドで書く。
    let task = Task.detached { [handle = process.stdinHandle] in
      try? handle?.write(contentsOf: input)
      try? handle?.close()
    }
    _ = task
  } else {
    process.closeStdin()
  }
  // 呼んだ Task が取り消されたら（転送の中止など）、コマンドを止める。
  let pid = process.pid
  let code = await withTaskCancellationHandler {
    await process.exitCode
  } onCancel: {
    Darwin.kill(pid, SIGTERM)
  }
  await process.waitForOutput()
  return ProcResult(exitCode: code, stdoutData: out, stderrData: err)
}

extension RunningProcess {
  fileprivate var stdinHandle: FileHandle? { stdinPipe?.fileHandleForWriting }
}

/// [executable] を、このアプリに紐づかないプロセスとして実行し、終わるまで待つ。
/// macOS は、アプリの子プロセスが launchd に登録したサービスをそのアプリのバックグラウンド項目として扱い、
/// アプリを終了するときに「バックグラウンドで実行中」と聞いて止めてしまう。それを避けるため、子プロセスの「責任元」を
/// アプリから外して起動する（responsibility_spawnattrs_setdisclaim。非公開だが iTerm2・VS Code なども使っている）。
/// その関数がないか、その形で起動できなければ nil を返す（呼んだ側で普通に起動し直す）。
nonisolated func runDisclaimed(_ executable: String, _ arguments: [String]) async -> ProcResult? {
  typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
  // RTLD_DEFAULT（読み込み済みのすべてのライブラリから探す）。
  guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
    return nil
  }
  let disclaim = unsafeBitCast(symbol, to: Disclaim.self)
  var attributes: posix_spawnattr_t?
  guard posix_spawnattr_init(&attributes) == 0 else { return nil }
  defer { posix_spawnattr_destroy(&attributes) }
  // 0・1・2 以外の記述子は子に渡さない。
  guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
    disclaim(&attributes, 1) == 0 else { return nil }
  let output = Pipe()
  let errors = Pipe()
  var actions: posix_spawn_file_actions_t?
  guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
  defer { posix_spawn_file_actions_destroy(&actions) }
  posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
  posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, 1)
  posix_spawn_file_actions_adddup2(&actions, errors.fileHandleForWriting.fileDescriptor, 2)
  let path = resolveExecutable(executable)
  let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
  defer { argv.forEach { free($0) } }
  var pid: pid_t = 0
  guard posix_spawn(&pid, path, &actions, &attributes, argv, environ) == 0 else { return nil }
  ChildProcesses.add(pid)
  try? output.fileHandleForWriting.close()
  try? errors.fileHandleForWriting.close()
  return await Task.detached {
    // 出力を読みきってから待つ（パイプが詰まって子が止まらないよう、両方を並べて読む）。
    async let out = output.fileHandleForReading.readDataToEndOfFile()
    async let err = errors.fileHandleForReading.readDataToEndOfFile()
    let (stdout, stderr) = await (out, err)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    ChildProcesses.remove(pid)
    // 下位7ビットが0なら終了コード、そうでなければシグナル番号（負の値で表す）。
    let signal = status & 0x7f
    let code = signal == 0 ? Int((status >> 8) & 0xff) : -Int(signal)
    return ProcResult(exitCode: code, stdoutData: stdout, stderrData: stderr)
  }.value
}

/// [executable] を実行し、失敗したら標準エラー出力を [CommandFailed] で投げる。
func runOrThrow(_ executable: String, _ arguments: [String]) async throws {
  let result = try await runProcess(executable, arguments)
  if result.exitCode != 0 {
    throw CommandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}
