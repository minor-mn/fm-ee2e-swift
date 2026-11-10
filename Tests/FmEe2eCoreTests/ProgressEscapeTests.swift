import Foundation
import Testing

@testable import FmEe2eCore

/// 画面を出さずにキーだけを送る窓。
private final class TestHost: FmEe2eCore.Host {
  let keys = Broadcast<Key>()
  let resizes = Broadcast<Void>()
  var width: Int { 80 }
  var height: Int { 24 }
  var inputFilter: (([UInt8]) -> [UInt8])?
  var focusedField: (() -> InputField?)?
  var sizer: GridSizer? { nil }
  func present(_ screen: Screen) {}
}

private final class EmptyView: View {
  func draw(_ screen: Screen) {}
  func handleKey(_ key: Key) {}
}

@MainActor
@Suite(.serialized)
struct ProgressEscapeTests {
  /// [action] を「お待ちください」で動かし、[after] ミリ秒後に Esc を送る。投げたエラーとかかった秒数を返す。
  private func pressEscape(after: Int, _ action: @escaping () async throws -> Void) async -> (Error?, Double) {
    let host = TestHost()
    let app = App(host)
    Task { await app.run(EmptyView()) }
    Task {
      try? await Task.sleep(for: .milliseconds(after))
      host.keys.add(.named("escape"))
    }
    let start = Date()
    var thrown: Error?
    do {
      try await app.withProgress("test") { try await action() }
    } catch {
      thrown = error
    }
    app.quit()
    return (thrown, Date().timeIntervalSince(start))
  }

  @Test("Esc で外部コマンドを止めて CancellationError になる")
  func process() async {
    let (error, seconds) = await pressEscape(after: 300) { _ = try await runProcess("/bin/sleep", ["30"]) }
    #expect(error is CancellationError)
    #expect(seconds < 5)
  }

  @Test("Esc でエラーを投げない処理を止めても CancellationError になる")
  func nonThrowing() async {
    let (error, seconds) = await pressEscape(after: 300) { _ = try? await runProcess("/bin/sleep", ["30"]) }
    #expect(error is CancellationError)
    #expect(seconds < 5)
  }

  @Test("応答しない接続先への SSH の接続を Esc で止める")
  func sshConnecting() async throws {
    // 経路のないアドレス（TEST-NET-1）。つながらず、待ち続ける。
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fm-ssh-" + UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let ssh = Ssh("192.0.2.1", p.join(dir, "master"))
    let (error, seconds) = await pressEscape(after: 500) { _ = try await ssh.connectWithoutPrompt() }
    #expect(error is CancellationError)
    #expect(seconds < 5)
  }
}
