import Darwin
import Foundation

/// 文言だけのエラー（Dart の StateError・FormatException などの代わり）。
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

/// Dart の ProcessException に当たるもの。
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

  var description: String { message.isEmpty ? "\(executable) \(arguments.joined(separator: " ")) が失敗しました" : message }
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
nonisolated func exitStatusText(_ exitCode: Int) -> String { "[終了コード \(shellStatus(exitCode))]" }

/// 外部コマンドの結果。
nonisolated struct ProcResult: Sendable {
  /// シグナルで終わったときは、負のシグナル番号（Dart と同じ）。
  let exitCode: Int
  let stdoutData: Data
  let stderrData: Data

  /// UTF-8 として読む（不正なバイトは置き換える）。
  var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
  var stderr: String { String(decoding: stderrData, as: UTF8.self) }
}

/// 実行ファイルを探す。「/」を含まなければ PATH から探す（Dart の Process.run と同じ）。
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

/// 実行中の外部コマンド（Dart の Process.start の代わり）。
/// 標準出力・標準エラー出力は [onStdout]・[onStderr] に、読めた順にメインスレッドで渡す。
final class RunningProcess {
  /// [environment] は今の環境変数に足す（Dart と同じ）。
  init(
    _ executable: String,
    _ arguments: [String],
    workingDirectory: String? = nil,
    environment: [String: String]? = nil,
    inheritStdio: Bool = false
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
    if inheritStdio {
      stdinPipe = nil
      stdoutPipe = nil
      stderrPipe = nil
    } else {
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
    }
    process.terminationHandler = { [weak self] p in
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
      throw ProcessError(executable, arguments, "\(executable) を実行できません: \(error.localizedDescription)", -1)
    }
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

/// 外部コマンドを実行して、終わるまで待つ（Dart の Process.run の代わり）。
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
  let code = await process.exitCode
  await process.waitForOutput()
  return ProcResult(exitCode: code, stdoutData: out, stderrData: err)
}

extension RunningProcess {
  fileprivate var stdinHandle: FileHandle? { stdinPipe?.fileHandleForWriting }
}

/// [executable] を実行し、失敗したら標準エラー出力を [CommandFailed] で投げる。
func runOrThrow(_ executable: String, _ arguments: [String]) async throws {
  let result = try await runProcess(executable, arguments)
  if result.exitCode != 0 {
    throw CommandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

/// 端末をそのまま渡して [executable] を実行し、終了コードを返す。
func runInherited(_ executable: String, _ arguments: [String], workingDirectory: String? = nil) async throws -> Int {
  let process = try RunningProcess(executable, arguments, workingDirectory: workingDirectory, inheritStdio: true)
  return await process.exitCode
}
