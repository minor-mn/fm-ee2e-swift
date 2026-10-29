import Foundation

/// SSH の接続先の [cwd] で補完する。名前は、つないでいる接続の上で接続先に問い合わせる。
final class RemoteCompletion: CompletionSource {
  init(_ ssh: Ssh, _ cwd: String) {
    self.ssh = ssh
    self.cwd = cwd
  }

  let ssh: Ssh

  /// 今のフォルダー（リモートの絶対パス）。
  let cwd: String

  private var home: String?

  /// 接続先の `sh -c` の PATH にある、[prefix] で始まる実行できるファイル。
  func commands(_ prefix: String) async throws -> Set<String> {
    do {
      let out = try await ssh.run(
        "IFS=:; for d in $PATH; do [ -d \"$d\" ] || continue; "
          + "for f in \"$d\"/\(shQuote(prefix))*; do [ -f \"$f\" ] && [ -x \"$f\" ] && printf '%s\\0' \"${f##*/}\"; done; done; "
          // 最後に調べたファイルが実行できなくても、失敗にしない。
          + "exit 0"
      )
      return Set(String(decoding: out, as: UTF8.self).components(separatedBy: "\0").filter { !$0.isEmpty })
    } catch is SshException {
      return []
    }
  }

  func files(_ dir: String) async throws -> [String: Bool] {
    var path = dir.isEmpty ? "." : dir
    if path == "~" || path.hasPrefix("~/") {
      if home == nil {
        home = try await ssh.home()
      }
      path = expandHome(path, home!)
    }
    do {
      var result: [String: Bool] = [:]
      for entry in try await ssh.list(PathContext.posix.join(cwd, path)) {
        result[entry.name] = entry.isDir
      }
      return result
    } catch is SshException {
      return [:]
    }
  }
}
