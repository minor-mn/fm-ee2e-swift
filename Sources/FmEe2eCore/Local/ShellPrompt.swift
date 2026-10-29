import Darwin
import Foundation

/// ログインシェル（$SHELL）。bash と zsh 以外は bash で代用する。
private nonisolated var shell: String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/bash" }

private nonisolated var isZsh: Bool { p.basename(shell) == "zsh" }

private nonisolated var historyFile: String { p.join(homeDir, isZsh ? ".zsh_history" : ".bash_history") }

/// [command] をシェルで実行するコマンドライン。設定が効くようログインシェルとして起動する。
/// 対話シェル（-i）にはしない。ジョブ制御でコマンドが別のプロセスグループになり、その間に押したキーで
/// このアプリの標準入力の読み取りが壊れる（tail -f 中に Enter を押して Ctrl+C で止めると、戻っても入力が効かない）。
nonisolated func shellCommand(_ command: String) -> [String] {
  if isZsh {
    return [shell, "-l", "-o", "aliases", "-c", command]
  }
  return [p.basename(shell) == "bash" ? shell : "/bin/bash", "-l", "-O", "expand_aliases", "-c", command]
}

private nonisolated let zshExtended = try! Regex(#"^: \d+:\d+;(.*)$"#).matchingSemantics(.unicodeScalar)
private nonisolated let timestamp = try! Regex(#"^#\d+$"#).matchingSemantics(.unicodeScalar)

/// シェルのヒストリー（古い順、重複は新しい方だけ残す）。
func loadShellHistory() async -> [String] {
  guard let data = FileManager.default.contents(atPath: historyFile) else {
    return []
  }
  // LineSplitter と同じく、\n・\r\n・\r で分ける。
  let lines = String(decoding: data, as: UTF8.self).split(
    omittingEmptySubsequences: false,
    whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
  )
  var commands: [String] = []
  for line in lines.map(String.init) {
    if isZsh {
      // 拡張形式は「: 開始時刻:経過秒;コマンド」。
      if let match = line.firstMatch(of: zshExtended) {
        commands.append(regexGroup(match, 1)!)
      } else {
        commands.append(line)
      }
    } else if line.firstMatch(of: timestamp) == nil {
      // 「#数字」は HISTTIMEFORMAT の時刻。
      commands.append(line)
    }
  }
  var seen = Set<String>()
  var unique: [String] = []
  for c in commands.reversed() {
    if !c.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert(c).inserted {
      unique.append(c)
    }
  }
  return unique.reversed()
}

/// [command] をシェルのヒストリーに追加する。
func appendShellHistory(_ command: String) async throws {
  let now = Int(Date().timeIntervalSince1970)
  let line = isZsh ? ": \(now):0;\(command)" : command
  let fd = open(historyFile, O_WRONLY | O_APPEND | O_CREAT, 0o666)
  if fd < 0 {
    throw FileSystemException("Cannot open file: \(String(cString: strerror(errno)))", historyFile)
  }
  defer { close(fd) }
  let bytes = Array("\(line)\n".utf8)
  if write(fd, bytes, bytes.count) != bytes.count {
    throw FileSystemException("Cannot write file: \(String(cString: strerror(errno)))", historyFile)
  }
  fsync(fd)
}
