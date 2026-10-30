import Foundation

/// ssh・scp コマンド。1つのホストに ControlMaster で1本つなぎ、コマンドと転送はその接続を使い回す。
///
/// 一覧やファイルの操作は、リモートで `sh -c` を実行して行う（ログインシェルが fish などでも同じ書き方で済むように）。
/// 転送は従来の SCP プロトコル（scp -O）で行う。
///
/// [via] があれば、その接続先で ssh を実行してつなぐ（その接続先の ~/.ssh/config と鍵を使う）。
/// そのときの [controlPath] は [via] の接続先のパスで、scp の転送はできない。
class Ssh {
  init(_ host: String, _ controlPath: String, via: Ssh? = nil) {
    self.host = host
    self.controlPath = controlPath
    self.via = via
  }

  static let executable = "/usr/bin/ssh"
  static let scpExecutable = "/usr/bin/scp"

  /// ~/.ssh/config の Host 名。
  let host: String

  /// ControlMaster のソケット。
  let controlPath: String

  /// この接続先へは、この接続先で ssh を実行してつなぐ。この Mac から直接つなぐなら nil。
  let via: Ssh?

  /// この接続先への ssh の引数 [args] を、この Mac で実行する ssh（[executable]）の引数にする。
  /// [via] があれば、その接続先のログインシェルに ssh を実行させる。[tty] なら途中の接続にも端末を割り当てる。
  private func wrap(_ args: [String], tty: Bool = false) throws -> [String] {
    guard let via else {
      return args
    }
    return try via.wrap(
      via.options + (tty ? ["-tt"] : []) + ["--", via.host, try (["ssh"] + args).map(shellWord).joined(separator: " ")],
      tty: tty
    )
  }

  /// つないだあとのコマンドは、マスターの接続だけを使う（切れていたら認証を聞かずに失敗する）。
  private var options: [String] {
    [
      "-o", "ControlMaster=no", "-o", "ControlPath=\(controlPath)", "-o", "BatchMode=yes",
      // マスターが失われた場合、別の接続を勝手に作らずに失敗させる。
      "-o", "ProxyCommand=false",
    ]
  }

  /// マスターの接続を作る引数。つながったら裏に回る。[batch] なら何も聞かずに、聞く必要があれば失敗する。
  /// [via] の接続先で作るときは、-f で裏に回ったマスターが出力をつないだままにして途中の接続が終わらないことがあるので、
  /// -f を使わず true を実行させる（ControlPersist で裏に回るマスターは、出力を /dev/null につなぎ直す）。
  /// [inTerminal]（枠の中の端末で聞く）ときも、-f で裏に回ったマスターが端末をつないだままにしないよう、同じく true を実行させる。
  private func masterArgs(batch: Bool = false, inTerminal: Bool = false) throws -> [String] {
    var args = ["-o", "ControlMaster=yes", "-o", "ControlPath=\(controlPath)", "-o", "ControlPersist=1h"]
    if batch {
      args += ["-o", "BatchMode=yes"]
    }
    let runsTrue = via != nil || inTerminal
    if !runsTrue {
      args += ["-f", "-N"]
    }
    args += ["--", host]
    if runsTrue {
      args.append("true")
    }
    return try wrap(args, tty: !batch)
  }

  /// マスターの接続を作る実行ファイルと引数。パスワードやパスフレーズを聞かれるので、枠の中の端末で実行する。
  /// 終了時に [close] で閉じる。閉じ忘れても、1時間使わなければ閉じる。
  func connectCommand() throws -> (String, [String]) { (Ssh.executable, try masterArgs(inTerminal: true)) }

  /// 何も聞かずに（鍵や ssh-agent だけで）マスターの接続を作る。つながったら true。
  /// パスワードや、初めてのホストの鍵の確認が要るときは false（そのときは [connect] で聞く）。
  func connectWithoutPrompt() async throws -> Bool {
    let process = try RunningProcess(Ssh.executable, try masterArgs(batch: true))
    // 裏に回ったマスターが出力をつないだままにしても待たないよう、出力は読み捨てて（onStdout・onStderr なし）終了コードだけを待つ。
    return await process.exitCode == 0
  }

  /// マスターの接続が生きているか。
  func alive() async throws -> Bool {
    let result = try await runProcess(Ssh.executable, try wrap(["-o", "ControlPath=\(controlPath)", "-O", "check", "--", host]))
    return result.exitCode == 0
  }

  /// マスターの接続を閉じる。
  func close() async throws {
    try await runProcess(Ssh.executable, try wrap(["-o", "ControlPath=\(controlPath)", "-O", "exit", "--", host]))
  }

  /// リモートのログインシェルで [command] を実行する（テストでは差し替える）。
  func exec(_ command: String) async throws -> ProcResult {
    try await runProcess(Ssh.executable, try wrap(options + ["--", host, command]))
  }

  /// リモートの `sh -c` で [script]（1行）を実行し、標準出力を返す。失敗したら [SshException]。
  @discardableResult
  func run(_ script: String) async throws -> Data {
    let result = try await exec("sh -c \(try shellWord(script))")
    if result.exitCode != 0 {
      let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      throw SshException(message.isEmpty ? tr("ssh.exit_code", ["code": result.exitCode]) : message)
    }
    return result.stdoutData
  }

  /// リモートの [path] を、手元の [local] に書き出す（cat の出力を、読めた分ずつ書く）。失敗したら [SshException]。
  /// [started] には、途中でやめる関数を渡す。やめたら [CancellationError] を投げる。
  func download(_ path: String, to local: String, started: (_ stop: @escaping () -> Void) -> Void = { _ in }) async throws {
    guard FileManager.default.createFile(atPath: local, contents: nil) else {
      throw FileSystemException(tr("ssh.cannot_create_file"), local)
    }
    let file = try FileHandle(forWritingTo: URL(fileURLWithPath: local))
    defer {
      try? file.close()
    }
    let process = try RunningProcess(Ssh.executable, try wrap(options + ["--", host, "sh -c \(try shellWord("cat \(shQuote(path))"))"]))
    var writeError: (any Error)?
    var err = Data()
    process.onStdout = { [weak process] data in
      guard writeError == nil else { return }
      do {
        try file.write(contentsOf: data)
      } catch {
        writeError = error
        process?.kill()
      }
    }
    process.onStderr = { err.append($0) }
    process.closeStdin()
    var stopped = false
    started { [weak process] in
      stopped = true
      process?.kill()
    }
    let code = await process.exitCode
    await process.waitForOutput()
    if stopped {
      throw CancellationError()
    }
    if let writeError {
      throw writeError
    }
    if code != 0 {
      let message = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      throw SshException(message.isEmpty ? tr("ssh.exit_code", ["code": code]) : message)
    }
  }

  /// [run] の出力から、最後の改行を除いた文字列。
  private func runLine(_ script: String) async throws -> String {
    var text = String(decoding: try await run(script), as: UTF8.self)
    if text.unicodeScalars.last == "\n" {
      text = String(text.unicodeScalars.dropLast())
    }
    return text
  }

  /// ログインしたときのフォルダー（ホーム）。
  func home() async throws -> String { try await runLine("pwd") }

  /// 移動先が存在するディレクトリであることを確認し、リモートの絶対パスを返す。
  func directory(_ path: String) async throws -> String { try await runLine("cd \(shQuote(path)) && pwd -P") }

  /// 一覧で開いている場所から、[file] をエディタ（接続先の $EDITOR、なければ vim）で開く。認証済みの接続を共有する。
  func interactiveArgs(_ dir: String, file: String) throws -> [String] {
    try ttyArgs(dir, "exec ${EDITOR:-vim} \(shQuote(file))")
  }

  /// 一覧で開いている場所で、[command] をログインシェルに実行させる。非対話なので、接続先のヒストリーには残らない。
  func commandArgs(_ dir: String, _ command: String) throws -> [String] {
    try ttyArgs(dir, "exec \"${SHELL:-/bin/sh}\" -l -c \(shQuote(command))")
  }

  /// 接続先の `sh -c` で git を [args] で実行する引数。[tty] なら端末を割り当てる（push の認証などを聞かれても答えられるように）。
  func gitArgs(_ args: [String], tty: Bool = false) throws -> [String] {
    try wrap(
      options + (tty ? ["-tt"] : [])
        + ["--", host, "sh -c \(try shellWord("exec git \(args.map(shQuote).joined(separator: " "))"))"],
      tty: tty
    )
  }

  /// 端末を割り当てて、[dir] で [script] を `sh -c` に実行させる引数。
  private func ttyArgs(_ dir: String, _ script: String) throws -> [String] {
    try wrap(options + ["-tt", "--", host, "sh -c \(try shellWord("cd \(shQuote(dir)) && \(script)"))"], tty: true)
  }

  /// [dir] の項目（隠しファイルを含む。. と .. は含めない）。
  func list(_ dir: String) async throws -> [RemoteEntry] {
    let out = try await run(
      "cd \(shQuote(dir)) || exit 1; LC_ALL=C ls -la; printf '\\0'; "
        + "for f in .* *; do [ -e \"$f\" ] || [ -L \"$f\" ] || continue; case $f in .|..) continue;; esac; "
        + "if [ -d \"$f\" ]; then printf 'd%s\\0' \"$f\"; else printf 'f%s\\0' \"$f\"; fi; done"
    )
    return parseRemoteList(out, Date())
  }

  /// [dir] のファイルシステムの容量（バイト）。
  func usage(_ dir: String) async throws -> DiskUsage? {
    parseDf(String(decoding: try await run("df -kP \(shQuote(dir))"), as: UTF8.self))
  }

  /// 接続先で使える圧縮の形式。zip は zip コマンド、tar.gz・tar.xz は tar と gzip・xz があるとき。
  func archiveFormats() async throws -> [ArchiveFormat] {
    let out = try await runLine(
      "has() { command -v \"$1\" >/dev/null 2>&1; }; "
        + "has zip && echo zip; has tar && has gzip && echo tar.gz; has tar && has xz && echo tar.xz; true"
    )
    let names = Set(out.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    return ArchiveFormat.allCases.filter { names.contains($0.label) }
  }

  /// 接続先で、[paths] をまとめて [output] に [format] で圧縮する。中の名前は各項目の名前から始める。
  /// 項目は別々のフォルダーにあってよい。失敗したら作りかけの [output] を消す。
  func compress(_ paths: [String], _ output: String, _ format: ArchiveFormat) async throws {
    // 「-」で始まる名前をオプションと誤認させない。
    func name(_ path: String) -> String {
      let base = PathContext.posix.basename(path)
      return shQuote(base.hasPrefix("-") ? "./\(base)" : base)
    }

    let script: String
    switch format {
    // zip には tar の -C がないので、項目ごとにそのフォルダーへ移って書き足す。-y はシンボリックリンクをそのまま入れる。
    case .zip:
      script = paths.map {
        "(cd \(shQuote(PathContext.posix.dirname($0))) && zip -q -r -y \(shQuote(output)) \(name($0)))"
      }.joined(separator: " && ")
    default:
      script = (["tar -c \(format.tarOptions.joined(separator: " ")) -f \(shQuote(output))"]
        + paths.map { "-C \(shQuote(PathContext.posix.dirname($0))) \(name($0))" }).joined(separator: " ")
    }
    try await run("{ \(script); } || { rm -f \(shQuote(output)); exit 1; }")
  }

  // パスはどれも絶対パスなので、「-」で始まってオプションと間違われることはない。

  func mkdir(_ path: String) async throws { try await run("mkdir \(shQuote(path))") }

  func touch(_ path: String) async throws { try await run("touch \(shQuote(path))") }

  func move(_ from: String, _ to: String) async throws { try await run("mv \(shQuote(from)) \(shQuote(to))") }

  func copy(_ from: String, _ to: String) async throws { try await run("cp -R \(shQuote(from)) \(shQuote(to))") }

  /// 消す（ゴミ箱はない）。
  func remove(_ paths: [String]) async throws { try await run("rm -rf \(paths.map(shQuote).joined(separator: " "))") }

  func chmod(_ mode: Int, _ path: String) async throws { try await run("chmod \(String(mode, radix: 8)) \(shQuote(path))") }

  func exists(_ path: String) async throws -> Bool {
    !(try await run("if [ -e \(shQuote(path)) ] || [ -L \(shQuote(path)) ]; then printf 1; fi")).isEmpty
  }

  /// フォルダー（フォルダーへのシンボリックリンクを含む）か。
  func isDirectory(_ path: String) async throws -> Bool {
    !(try await run("if [ -d \(shQuote(path)) ]; then printf 1; fi")).isEmpty
  }

  /// 転送完了後に置き換えるため、送り先と同じファイルシステムに一時領域を作る。
  func transferTemp(_ parent: String) async throws -> String {
    try await runLine("mktemp -d \(shQuote(PathContext.posix.join(parent, ".fm-ee2e-scp.XXXXXX")))")
  }

  /// リモートの [path] を scp で指す形（host:path）。scp -O はパスをリモートのシェルに渡す。
  func remote(_ path: String) throws -> String { "\(host):\(try shellWord(path))" }

  /// scp の引数。[from]・[to] のどちらかは [remote] の形にする。
  func scpArgs(_ from: String, _ to: String) -> [String] { ["-O", "-r"] + options + ["--", from, to] }

  /// scp で [from] から [to] へ送るプログラムと引数。[via] があれば、その接続先で scp を実行する
  /// （そこにあるこの接続先のマスターの接続を使い、[via] の接続先と、この接続先の間で送る）。
  func scpCommand(_ from: String, _ to: String) throws -> (String, [String]) {
    guard let via else {
      return (Ssh.scpExecutable, scpArgs(from, to))
    }
    return (
      Ssh.executable,
      try via.wrap(
        via.options + ["--", via.host, try (["scp"] + scpArgs(from, to)).map(shellWord).joined(separator: " ")]
      )
    )
  }
}

nonisolated struct SshException: Error, CustomStringConvertible {
  init(_ message: String) {
    self.message = message
  }

  let message: String

  var description: String { message }
}

/// リモートの一覧の1項目。
nonisolated struct RemoteEntry: Sendable {
  init(
    name: String,
    isDir: Bool,
    isLink: Bool = false,
    size: Int? = nil,
    modified: Date? = nil,
    mode: Int? = nil,
    permissions: String? = nil,
    owner: String? = nil,
    group: String? = nil
  ) {
    self.name = name
    self.isDir = isDir
    self.isLink = isLink
    self.size = size
    self.modified = modified
    self.mode = mode
    self.permissions = permissions
    self.owner = owner
    self.group = group
  }

  let name: String

  /// フォルダー（フォルダーへのシンボリックリンクを含む）。
  let isDir: Bool
  let isLink: Bool
  let size: Int?
  let modified: Date?

  /// パーミッション（setuid などを含む下位12ビット）。
  let mode: Int?

  /// ls -l の形（drwxr-xr-x）。
  let permissions: String?
  let owner: String?
  let group: String?
}

/// POSIX sh の1語として、' で囲む。
nonisolated func shQuote(_ s: String) -> String { "'\(s.replacingOccurrences(of: "'", with: #"'\''"#))'" }

/// リモートのログインシェル（sh・bash・zsh・fish）が1語として読む形。特殊な文字の前に \ を付ける。
/// 改行は \ を付けても消えてしまうので扱えない。
nonisolated func shellWord(_ s: String) throws -> String {
  if s.unicodeScalars.contains("\n") {
    throw SshException(tr("ssh.newline_in_name"))
  }
  if s.isEmpty {
    return "''"
  }
  var out = String.UnicodeScalarView()
  for c in s.unicodeScalars {
    if isRegExpSpace(c) || "\\'\"$`&|;<>(){}[]*?~#^%".unicodeScalars.contains(c) {
      out.append("\\")
    }
    out.append(c)
  }
  return String(out)
}

private nonisolated let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

/// LC_ALL=C の ls -l の1行（GNU・BSD・BusyBox）。デバイスファイルはサイズの代わりに「8, 1」が出る。
private nonisolated let lsLine = try! Regex(
  #"^([-bcdlps])([-rwxsStT]{9})\S*\s+\S+\s+(\S+)\s+(\S+)\s+(\d+|\d+,\s*\d+)\s+(\w{3})\s+(\d{1,2})\s+(\d{1,2}:\d{2}|\d{4}) (.*)$"#
).matchingSemantics(.unicodeScalar)

/// [Ssh.list] の出力を読む。ls -la の出力、NUL、「d名前」「f名前」の NUL 区切りの順。
/// 名前と種類は後半を正とし、サイズ・日時などを ls -la の行から足す（シンボリックリンクの行は「名前 -> 先」なので、知っている名前で切る）。
nonisolated func parseRemoteList(_ out: Data, _ now: Date) -> [RemoteEntry] {
  guard let split = out.firstIndex(of: 0) else {
    return []
  }
  func decode(_ bytes: Data) -> String { String(decoding: bytes, as: UTF8.self) }
  // 名前は（正規化で同じとみなさないよう）バイト列で引き、書いた順に並べる（Dart の Map と同じ）。
  var names: [String] = []
  var kinds: [[UInt8]: Bool] = [:]
  for item in decode(out[(split + 1)...]).components(separatedBy: "\0") where item.utf16.count > 1 {
    let name = String(item.unicodeScalars.dropFirst())
    let key = Array(name.utf8)
    if kinds[key] == nil {
      names.append(name)
    }
    kinds[key] = item.unicodeScalars.first == "d"
  }
  var details: [[UInt8]: Regex<AnyRegexOutput>.Match] = [:]
  for line in decode(out[..<split]).components(separatedBy: "\n") {
    guard let m = line.firstMatch(of: lsLine) else {
      continue
    }
    var name = regexGroup(m, 9)!
    if regexGroup(m, 1) == "l" {
      // 「名前 -> 先」。名前に「 -> 」が入っていても、知っている名前のうち一番長いもので切る。
      var known: String?
      for k in names where Array(name.utf8).starts(with: Array("\(k) -> ".utf8)) {
        if known == nil || k.utf16.count > known!.utf16.count {
          known = k
        }
      }
      name = known ?? name.components(separatedBy: " -> ")[0]
    }
    details[Array(name.utf8)] = m
  }
  return names.map { name in
    let isDir = kinds[Array(name.utf8)]!
    guard let m = details[Array(name.utf8)] else {
      return RemoteEntry(name: name, isDir: isDir)
    }
    return RemoteEntry(
      name: name,
      isDir: isDir,
      isLink: regexGroup(m, 1) == "l",
      size: isDir ? nil : Int(regexGroup(m, 5)!),
      modified: parseDate(regexGroup(m, 6)!, regexGroup(m, 7)!, regexGroup(m, 8)!, now),
      mode: parseMode(regexGroup(m, 2)!),
      permissions: "\(regexGroup(m, 1)!)\(regexGroup(m, 2)!)",
      owner: regexGroup(m, 3),
      group: regexGroup(m, 4)
    )
  }
}

/// ls -l の「Oct 28 06:50」（半年以内）か「Oct 28  2025」。年がなければ、未来にならない年にする。
private nonisolated func parseDate(_ month: String, _ day: String, _ timeOrYear: String, _ now: Date) -> Date? {
  let m = (months.firstIndex(of: month) ?? -1) + 1
  let d = Int(day)!
  if m == 0 {
    return nil
  }
  if !timeOrYear.contains(":") {
    return localDateTime(Int(timeOrYear)!, m, d)
  }
  let parts = timeOrYear.split(separator: ":").map { Int($0)! }
  let (hour, minute) = (parts[0], parts[1])
  let year = yearOf(now)
  let date = localDateTime(year, m, d, hour, minute)
  return date > now.addingTimeInterval(86400) ? localDateTime(year - 1, m, d, hour, minute) : date
}

/// 「rwxr-sr-t」を下位12ビットにする。
private nonisolated func parseMode(_ text: String) -> Int {
  let s = Array(text.utf8)
  var mode = 0
  for i in 0..<9 {
    let c = s[i]
    if c != UInt8(ascii: "-") && c != UInt8(ascii: "S") && c != UInt8(ascii: "T") {
      mode |= 1 << (8 - i)
    }
  }
  if s[2] == UInt8(ascii: "s") || s[2] == UInt8(ascii: "S") {
    mode |= 0x800
  }
  if s[5] == UInt8(ascii: "s") || s[5] == UInt8(ascii: "S") {
    mode |= 0x400
  }
  if s[8] == UInt8(ascii: "t") || s[8] == UInt8(ascii: "T") {
    mode |= 0x200
  }
  return mode
}

/// ~/.ssh/config（と Include したファイル）の Host 名。* などのパターンは除く。書いてある順。
func readSshHosts(_ configPath: String) async throws -> [String] {
  try await readSshHosts(
    configPath,
    read: { path in
      try? String(contentsOfFile: path, encoding: .utf8)
    },
    expand: { pattern in
      expandInclude(pattern, p.dirname(configPath))
    }
  )
}

/// [via] の接続先の ~/.ssh/config（と Include したファイル）の Host 名。~/.ssh/config がなければ nil。
func readRemoteSshHosts(_ via: Ssh) async throws -> [String]? {
  let home = try await via.home()
  let sshDir = PathContext.posix.join(home, ".ssh")
  let config = PathContext.posix.join(sshDir, "config")
  if !(try await via.exists(config)) {
    return nil
  }
  return try await readSshHosts(
    config,
    read: { path in
      do {
        return String(decoding: try await via.run("cat \(shQuote(path))"), as: UTF8.self)
      } catch is SshException {
        return nil
      }
    },
    expand: { pattern in
      var path = expandHome(pattern, home)
      if !path.hasPrefix("/") {
        path = PathContext.posix.join(sshDir, path)
      }
      let name = PathContext.posix.basename(path)
      if !name.unicodeScalars.contains(where: { $0 == "*" || $0 == "?" }) {
        return [path]
      }
      // * と ? だけを接続先の sh に展開させ、ほかは ' で囲む。
      var glob = ""
      var part = String.UnicodeScalarView()
      for c in name.unicodeScalars {
        if c == "*" || c == "?" {
          if !part.isEmpty {
            glob += shQuote(String(part))
            part = String.UnicodeScalarView()
          }
          glob.unicodeScalars.append(c)
        } else {
          part.append(c)
        }
      }
      if !part.isEmpty {
        glob += shQuote(String(part))
      }
      let out = try await via.run(
        "for f in \(shQuote(PathContext.posix.dirname(path)))/\(glob); do [ -f \"$f\" ] && printf '%s\\0' \"$f\"; done; true"
      )
      return String(decoding: out, as: UTF8.self).components(separatedBy: "\0").filter { !$0.isEmpty }
        .sorted(by: codeUnitsBefore)
    }
  )
}

/// [configPath] から Host 名を集める。ファイルは [read]（読めなければ nil）、Include のパスは [expand] で読む。
private func readSshHosts(
  _ configPath: String,
  read: @escaping (String) async throws -> String?,
  expand: @escaping (String) async throws -> [String]
) async throws -> [String] {
  var hosts: [String] = []
  var seen = Set<String>()
  func readFile(_ path: String, _ depth: Int) async throws {
    guard let text = try await read(path) else {
      return
    }
    for (keyword, values) in parseSshConfigLines(text) {
      if keyword == "host" {
        for v in values where !v.unicodeScalars.contains(where: { "*?!".unicodeScalars.contains($0) }) {
          if seen.insert(v).inserted {
            hosts.append(v)
          }
        }
      } else if keyword == "include" && depth < 8 {
        for pattern in values {
          for file in try await expand(pattern) {
            try await readFile(file, depth + 1)
          }
        }
      }
    }
  }

  try await readFile(configPath, 0)
  return hosts
}

private nonisolated let configLine = try! Regex(#"^\s*([A-Za-z]+)\s*(?:=\s*|\s+)(.*)$"#)
  .matchingSemantics(.unicodeScalar)
private nonisolated let configValue = try! Regex(#""([^"]*)"|([^\s#]+)"#).matchingSemantics(.unicodeScalar)

/// ssh_config の行を（小文字のキーワード, 値）にする。「キー 値」「キー=値」、"" で囲んだ値に対応する。
nonisolated func parseSshConfigLines(_ text: String) -> [(String, [String])] {
  var result: [(String, [String])] = []
  for raw in text.components(separatedBy: "\n") {
    guard let m = raw.firstMatch(of: configLine),
      !raw.drop(while: { $0.unicodeScalars.allSatisfy(isRegExpSpace) }).hasPrefix("#")
    else {
      continue
    }
    var values: [String] = []
    for v in withoutComment(regexGroup(m, 2)!).trimmingCharacters(in: .whitespacesAndNewlines).matches(of: configValue) {
      let value = regexGroup(v, 1) ?? regexGroup(v, 2)!
      if !value.isEmpty {
        values.append(value)
      }
    }
    result.append((regexGroup(m, 1)!.lowercased(), values))
  }
  return result
}

private nonisolated func withoutComment(_ value: String) -> String {
  var quoted = false
  var out = String.UnicodeScalarView()
  for c in value.unicodeScalars {
    if c == "\"" {
      quoted = !quoted
    }
    if !quoted && c == "#" {
      return String(out)
    }
    out.append(c)
  }
  return value
}

/// Include のパス。相対パスは ~/.ssh から。* と ? は最後の部分でだけ展開する。
private nonisolated func expandInclude(_ pattern: String, _ sshDir: String) -> [String] {
  var path = expandHome(pattern, ProcessInfo.processInfo.environment["HOME"] ?? "")
  if !p.isAbsolute(path) {
    path = p.join(sshDir, path)
  }
  let name = p.basename(path)
  if !name.unicodeScalars.contains(where: { $0 == "*" || $0 == "?" }) {
    return [path]
  }
  let escaped = NSRegularExpression.escapedPattern(for: name)
    .replacingOccurrences(of: #"\*"#, with: ".*")
    .replacingOccurrences(of: #"\?"#, with: ".")
  guard let glob = try? Regex("^\(escaped)$").matchingSemantics(.unicodeScalar) else {
    return []
  }
  let dir = p.dirname(path)
  // 開けなければ空。
  guard let entities = try? listDirectory(dir) else {
    return []
  }
  return entities.filter { statPath($0).type == .file && p.basename($0).wholeMatch(of: glob) != nil }
    .sorted(by: codeUnitsBefore)
}
