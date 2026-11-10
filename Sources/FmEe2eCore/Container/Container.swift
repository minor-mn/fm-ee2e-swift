import Foundation

struct ContainerInfo: Equatable {
  let name: String
  let status: String
  var addresses: [String: String] = [:]
  var details = ContainerDetails()
  var running: Bool { status.lowercased() == "running" }
}

/// Mac のフォルダー [source] を、コンテナの中の [destination] につないだもの。
struct ContainerBind: Equatable {
  let source: String
  let destination: String
}

/// 接続前に上の帯に出す、コンテナの設定。作成済みなら Apple Container の一覧、未作成なら保存した作成設定から読む。
struct ContainerDetails: Equatable {
  var image: String?
  var platform: String?
  var rosetta = false
  var cpus: String?
  var memory: String?
  var ports: [String] = []
  var networks: [String] = []
  var addresses: [String] = []
  /// Mac のフォルダーをそのままつないだマウント（virtiofs）。作成済みのコンテナの一覧からだけ読む。
  var binds: [ContainerBind] = []
  /// コンテナの DNS ドメイン（--dns-domain）。コンテナ自身は「名前.ドメイン」で引ける。
  var dnsDomain: String?

  /// 保存した create の引数から読む。指定のない項目は空のまま（Apple Container の既定値を推測しない）。
  init(image: String? = nil, create: [String] = []) {
    self.image = image
    var index = 0
    while index < create.count {
      let flag = create[index]
      let value = index + 1 < create.count ? create[index + 1] : nil
      switch flag {
      case "--platform": platform = value
      case "--cpus", "-c": cpus = value
      case "--memory", "-m": memory = value
      case "--publish", "-p": value.map { ports.append($0) }
      case "--network": value.map { networks.append(String($0.prefix { $0 != "," })) }
      case "--dns-domain": dnsDomain = value
      case "--rosetta": rosetta = true; index += 1; continue
      default: index += 1; continue
      }
      index += 2
    }
  }
}

/// Apple Container 1.6.1 の CLI。引数はシェルに渡さず、そのまま実行する。
class ContainerClient {
  init(executable: String = resolveExecutable("container")) { self.executable = executable }
  let executable: String

  func execute(_ args: [String], in directory: String? = nil) async throws -> ProcResult {
    try await runProcess(executable, args, workingDirectory: directory)
  }

  @discardableResult
  func checked(_ args: [String], in directory: String? = nil, awsProfile: String? = nil) async throws -> ProcResult {
    var result = try await execute(args, in: directory)
    if result.exitCode != 0, ["create", "run", "build", "image"].contains(args.first ?? ""),
      (result.stderr.contains("401") || result.stderr.contains("403")),
      let registry = Self.ecrRegistry(in: result.stderr), let awsProfile, !awsProfile.isEmpty {
      try await authenticateEcr(registry.host, region: registry.region, profile: awsProfile)
      result = try await execute(args, in: directory)
    }
    if result.exitCode != 0 {
      let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      throw AppError(message.isEmpty ? exitStatusText(result.exitCode) : message)
    }
    return result
  }

  /// ECR のトークンは設定ファイルや引数に保存せず、標準入力で Apple Container に渡す。
  func authenticateEcr(_ host: String, region: String, profile: String? = nil) async throws {
    let password = try await runProcess("aws", ["ecr", "get-login-password", "--region", region] + (profile.map { ["--profile", $0] } ?? []))
    guard password.exitCode == 0, !password.stdoutData.isEmpty else {
      throw AppError(tr("container.ecr_login_failed", ["host": host, "error": password.stderr.trimmingCharacters(in: .whitespacesAndNewlines)]))
    }
    let login = try await runProcess(executable, ["registry", "login", "--username", "AWS", "--password-stdin", host], input: password.stdoutData)
    if login.exitCode != 0 {
      throw AppError(tr("container.ecr_login_failed", ["host": host, "error": login.stderr.trimmingCharacters(in: .whitespacesAndNewlines)]))
    }
  }

  static func ecrRegistry(in message: String) -> (host: String, region: String)? {
    let pattern = #"\b[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com(?:\.cn)?\b"#
    guard let range = message.range(of: pattern, options: .regularExpression) else { return nil }
    let host = String(message[range])
    return (host, host.components(separatedBy: ".")[3])
  }

  /// Apple Container のサービスを起動する（container system start をアプリから直接実行する）。
  func startSystem() async throws { _ = try await checked(["system", "start"]) }

  /// Apple Container のサービスを止める（動いているコンテナも止まる）。
  func stopSystem() async throws { _ = try await checked(["system", "stop"]) }

  /// --dns-domain を付けずに作ったコンテナが使う DNS ドメイン（container system property list の [dns] の domain）。
  func defaultDNSDomain() async -> String? {
    guard let result = try? await execute(["system", "property", "list"]), result.exitCode == 0 else { return nil }
    var section = ""
    for line in result.stdout.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }) {
      if line.hasPrefix("[") { section = line; continue }
      guard section == "[dns]", line.hasPrefix("domain") else { continue }
      let value = line.drop { $0 != "=" }.dropFirst().trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      return value.isEmpty ? nil : value
    }
    return nil
  }

  func systemRunning() async throws -> Bool {
    let result = try await execute(["system", "status"])
    return result.exitCode == 0 && result.stdout.components(separatedBy: .newlines).contains {
      $0.split(whereSeparator: \.isWhitespace).map(String.init) == ["status", "running"]
    }
  }

  /// 手元のイメージの名前（docker.io/library/redis:6.2 のような、正規化した形）。
  func imageNames() async throws -> Set<String> {
    guard let rows = try JSONSerialization.jsonObject(with: try await checked(["image", "list", "--format", "json"]).stdoutData) as? [[String: Any]] else {
      throw AppError(tr("container.invalid_list"))
    }
    return Set(rows.compactMap { ($0["configuration"] as? [String: Any])?["name"] as? String })
  }

  /// イメージの名前を、Apple Container の一覧と同じ形にする（redis:6.2 → docker.io/library/redis:6.2）。
  static func normalizedImage(_ image: String) -> String {
    let parts = image.split(separator: "/", maxSplits: 1).map(String.init)
    let named = image.contains(":") || image.contains("@") ? image : image + ":latest"
    if parts.count == 1 { return "docker.io/library/" + named }
    let host = parts[0]
    return host.contains(".") || host.contains(":") || host == "localhost" ? named : "docker.io/" + named
  }

  /// ローカルにある [image] の platform（linux/arm64 など）。Mac と同じ arm64 があればそれを、なければ amd64、それもなければ最初のもの。
  /// ローカルになければ nil。
  func preferredPlatform(_ image: String) async -> String? {
    guard let result = try? await execute(["image", "inspect", image]), result.exitCode == 0,
      let rows = try? JSONSerialization.jsonObject(with: result.stdoutData) as? [[String: Any]],
      let variants = rows.first?["variants"] as? [[String: Any]] else { return nil }
    let platforms = Self.platforms(variants)
    return platforms.first { $0 == "linux/arm64" } ?? platforms.first { $0 == "linux/amd64" } ?? platforms.first
  }

  /// イメージの variants（手元に取得してある platform ごとの中身）を、linux/arm64・linux/arm/v7 のような名前にする。
  /// 添付データ（unknown）は除く。arm64 の v8 は付けない。
  static func platforms(_ variants: [[String: Any]]) -> [String] {
    var result: [String] = []
    for variant in variants {
      guard let platform = variant["platform"] as? [String: Any], let os = platform["os"] as? String, let arch = platform["architecture"] as? String,
        os != "unknown", arch != "unknown" else { continue }
      let sub = platform["variant"] as? String ?? ""
      let name = [os, arch, sub.isEmpty || (arch == "arm64" && sub == "v8") ? nil : sub].compactMap { $0 }.joined(separator: "/")
      if !result.contains(name) { result.append(name) }
    }
    return result
  }

  /// この Mac で動かせる platform。Mac の CPU の platform と、Apple 製 CPU で Rosetta が有効（build.rosetta）なら linux/amd64。
  func runnablePlatforms() async throws -> [String] {
    func object(_ args: [String]) async throws -> [String: Any] {
      guard let value = try JSONSerialization.jsonObject(with: try await checked(args).stdoutData) as? [String: Any] else {
        throw AppError(tr("container.invalid_list"))
      }
      return value
    }
    let architecture = (try await object(["system", "status", "--format", "json"])["host"] as? [String: Any])?["architecture"] as? String ?? "arm64"
    let rosetta = (try await object(["system", "property", "list", "--format", "json"])["build"] as? [String: Any])?["rosetta"] as? Bool ?? false
    return ["linux/\(architecture)"] + (architecture == "arm64" && rosetta ? ["linux/amd64"] : [])
  }

  /// [names] のイメージの、platform ごとのレイヤーの一覧（rootfs.diff_ids）。キーは一覧と同じ名前（docker.io/library/… の形）。
  func imageLayers(_ names: [String]) async throws -> [String: [String: [String]]] {
    guard !names.isEmpty else { return [:] }
    guard let rows = try JSONSerialization.jsonObject(with: try await checked(["image", "inspect"] + names).stdoutData) as? [[String: Any]] else {
      throw AppError(tr("container.invalid_list"))
    }
    var result: [String: [String: [String]]] = [:]
    for row in rows {
      guard let name = (row["configuration"] as? [String: Any])?["name"] as? String else { continue }
      for variant in row["variants"] as? [[String: Any]] ?? [] {
        guard let platform = Self.platforms([variant]).first,
          let layers = ((variant["config"] as? [String: Any])?["rootfs"] as? [String: Any])?["diff_ids"] as? [String] else { continue }
        result[name, default: [:]][platform] = layers
      }
    }
    return result
  }

  /// 元のイメージ → それを元に作ったイメージ。あるイメージのレイヤーの先頭が、同じ platform のほかのイメージのレイヤーとすべて一致すれば、
  /// そのイメージを元にしている（一致するものが複数あれば、いちばん長く一致したもの）。
  static func derivedImages(_ layers: [String: [String: [String]]], platform: String) -> [String: [String]] {
    var result: [String: [String]] = [:]
    for (name, platforms) in layers {
      guard let own = platforms[platform] else { continue }
      let base = layers.filter { other in
        guard other.key != name, let theirs = other.value[platform] else { return false }
        return !theirs.isEmpty && theirs.count < own.count && Array(own.prefix(theirs.count)) == theirs
      }.max { ($0.value[platform]?.count ?? 0) < ($1.value[platform]?.count ?? 0) }
      if let base { result[base.key, default: []].append(name) }
    }
    return result.mapValues { $0.sorted() }
  }

  /// ローカルにあるイメージと、それぞれの platform（container image list の variants から）。
  func imagePlatforms() async throws -> [(name: String, platforms: [String])] {
    guard let rows = try JSONSerialization.jsonObject(with: try await checked(["image", "list", "--format", "json"]).stdoutData) as? [[String: Any]] else {
      throw AppError(tr("container.invalid_list"))
    }
    return rows.compactMap { row in
      guard let name = (row["configuration"] as? [String: Any])?["name"] as? String else { return nil }
      return (name, Self.platforms(row["variants"] as? [[String: Any]] ?? []))
    }
  }

  /// 一覧の名前（docker.io/library/redis:6.2）を、FROM などに書く短い形（redis:6.2）にする。Docker Hub 以外はそのまま。
  static func shortImage(_ image: String) -> String {
    for prefix in ["docker.io/library/", "docker.io/"] where image.hasPrefix(prefix) { return String(image.dropFirst(prefix.count)) }
    return image
  }

  /// --publish の値（[アドレス:]Mac側:コンテナ側[/プロトコル]）の、Mac 側のポートとプロトコル。Mac 側がなければ nil。
  static func publishedHostPort(_ value: String) -> (port: Int, proto: String)? {
    let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
    let proto = parts.count > 1 ? parts[1].lowercased() : "tcp"
    let ports = parts[0].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard ports.count >= 2, let port = Int(ports[ports.count - 2]) else { return nil }
    return (port, proto)
  }

  /// Mac 側で [port] を待ち受けているプロセス（名前と PID）。lsof で調べる。
  func hostListeners(_ port: Int, proto: String) async -> [(name: String, pid: String)] {
    let args = proto == "udp" ? ["-nP", "-iUDP:\(port)", "-Fpc"] : ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]
    guard let result = try? await runProcess("/usr/sbin/lsof", args), result.exitCode == 0 else { return [] }
    var listeners: [(name: String, pid: String)] = []
    var pid = ""
    for line in result.stdout.components(separatedBy: .newlines) {
      if line.hasPrefix("p") { pid = String(line.dropFirst()) }
      if line.hasPrefix("c") { listeners.append((String(line.dropFirst()), pid)) }
    }
    return listeners
  }

  /// ネットワークの名前とサブネット（名前順）。
  func networks() async throws -> [(name: String, subnet: String)] {
    guard let rows = try JSONSerialization.jsonObject(with: try await checked(["network", "list", "--format", "json"]).stdoutData) as? [[String: Any]] else {
      throw AppError(tr("container.invalid_list"))
    }
    return rows.compactMap { row in
      guard let name = row["id"] as? String else { return nil }
      return (name, (row["status"] as? [String: Any])?["ipv4Subnet"] as? String ?? "")
    }.sorted { $0.name < $1.name }
  }

  func list() async throws -> [ContainerInfo] {
    try Self.parseList(try await checked(["list", "--all", "--format", "json"]).stdoutData)
  }

  static func parseList(_ data: Data) throws -> [ContainerInfo] {
    guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      throw AppError(tr("container.invalid_list"))
    }
    return try rows.map { row in
      let config = row["configuration"] as? [String: Any] ?? [:]
      let state = row["status"] as? [String: Any] ?? [:]
      guard let name = config["id"] as? String ?? row["id"] as? String,
        let status = (row["status"] as? [String: Any])?["state"] as? String ?? row["status"] as? String, !name.isEmpty
      else { throw AppError(tr("container.invalid_list")) }
      var addresses: [String: String] = [:]
      for network in state["networks"] as? [[String: Any]] ?? [] {
        if let name = network["network"] as? String, let address = network["ipv4Address"] as? String {
          addresses[name] = String(address.prefix(while: { $0 != "/" }))
        }
      }
      var details = ContainerDetails(image: (config["image"] as? [String: Any])?["reference"] as? String)
      if let platform = config["platform"] as? [String: Any], let os = platform["os"] as? String, let architecture = platform["architecture"] as? String {
        details.platform = "\(os)/\(architecture)" + ((platform["variant"] as? String).map { "/\($0)" } ?? "")
      }
      details.rosetta = config["rosetta"] as? Bool ?? false
      let resources = config["resources"] as? [String: Any] ?? [:]
      details.cpus = (resources["cpus"] as? NSNumber).map { "\($0)" }
      details.memory = (resources["memoryInBytes"] as? NSNumber).map { formatBytes($0.intValue) }
      details.ports = (config["publishedPorts"] as? [[String: Any]] ?? []).compactMap { port in
        guard let host = port["hostPort"] as? NSNumber, let container = port["containerPort"] as? NSNumber else { return nil }
        let address = (port["hostAddress"] as? String).flatMap { ["0.0.0.0", "::", ""].contains($0) ? nil : $0 + ":" } ?? ""
        let proto = (port["proto"] as? String).flatMap { $0 == "tcp" ? nil : "/" + $0 } ?? ""
        return "\(address)\(host):\(container)\(proto)"
      }
      details.networks = (config["networks"] as? [[String: Any]] ?? []).compactMap { $0["network"] as? String }
      details.dnsDomain = ((config["dns"] as? [String: Any])?["domain"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      details.addresses = details.networks.compactMap { addresses[$0] }
      details.binds = (config["mounts"] as? [[String: Any]] ?? []).compactMap { mount in
        guard (mount["type"] as? [String: Any])?["virtiofs"] != nil, let source = mount["source"] as? String,
          let destination = mount["destination"] as? String else { return nil }
        return ContainerBind(source: source, destination: destination)
      }
      return ContainerInfo(name: name, status: status, addresses: addresses, details: details)
    }
  }
}

/// SSH と同じリモートファイル操作を、container exec の sh で行う。
/// 接続を閉じてもコンテナ自体は止めない。
final class ContainerConnection: Ssh {
  init(_ name: String, client: ContainerClient, binds: [ContainerBind] = []) {
    self.client = client
    self.binds = binds
    super.init(name, "")
  }
  let client: ContainerClient
  /// コンテナの中のパスを Mac のパスに置き換えるための、バインドマウントの対応。
  let binds: [ContainerBind]

  /// [path] がバインドマウントの中なら、Mac 側のパス。いちばん深いマウントを選ぶ。外なら nil。
  func hostPath(_ path: String) -> String? {
    let path = PathContext.posix.normalize(path)
    let candidates = binds.filter {
      let destination = PathContext.posix.normalize($0.destination)
      return path == destination || path.hasPrefix(destination == "/" ? "/" : destination + "/")
    }
    guard let bind = candidates.max(by: { $0.destination.count < $1.destination.count }) else { return nil }
    let rest = String(path.dropFirst(PathContext.posix.normalize(bind.destination).count)).drop { $0 == "/" }
    return rest.isEmpty ? bind.source : p.join(bind.source, String(rest))
  }
  override var executionPath: String { client.executable }

  func execArgs(_ script: String, interactive: Bool = false, tty: Bool = false) -> [String] {
    ["exec"] + (interactive ? ["--interactive"] : []) + (tty ? ["--tty"] : []) + [host, "sh", "-c", script]
  }

  override func exec(_ command: String) async throws -> ProcResult { try await client.execute(execArgs(command)) }

  @discardableResult
  override func run(_ script: String) async throws -> Data { try await client.checked(execArgs(script)).stdoutData }

  /// 接続先の git も、container exec の sh で動かす。標準入力はいつも渡す（git apply などに入力を渡すため）。
  /// [tty] なら端末も割り当てる（認証を聞かれても答えられるように）。
  override func gitArgs(_ args: [String], dir: String? = nil, tty: Bool = false) throws -> [String] {
    execArgs(gitScript(args, dir: dir), interactive: true, tty: tty)
  }

  override func alive() async throws -> Bool { try await client.list().contains { $0.name == host && $0.running } }
  override func close() async throws {}
  override func downloadArgs(_ path: String) throws -> [String] { execArgs("cat \(shQuote(path))") }

  override func interactiveArgs(_ dir: String, file: String) throws -> [String] {
    execArgs("cd \(shQuote(dir)) && exec ${EDITOR:-vi} \(shQuote(file))", interactive: true, tty: true)
  }

  override func commandArgs(_ dir: String, _ command: String) throws -> [String] {
    execArgs("cd \(shQuote(dir)) && \(command)", interactive: true, tty: true)
  }
}

/// tar のストリームでコピーする。送り先は既存のない一時領域内のパス。
extension ContainerConnection {
  func copyTar(_ from: String, _ to: String, upload: Bool) async throws -> ProcResult {
    let context = PathContext.posix
    let name = context.basename(from)
    let archiveDir = context.join(context.dirname(to), "archive")
    let unpack = "mkdir \(shQuote(archiveDir)) && tar -xf - -C \(shQuote(archiveDir)) && mv \(shQuote(context.join(archiveDir, name))) \(shQuote(to))"
    let pack = "tar -cf - -C \(shQuote(context.dirname(from))) -- \(shQuote(name))"
    return try await runPipeline(
      upload ? "/usr/bin/tar" : executionPath,
      upload ? ["-cf", "-", "-C", p.dirname(from), "--", p.basename(from)] : execArgs(pack),
      upload ? executionPath : "/bin/sh",
      upload ? execArgs(unpack, interactive: true) : ["-c", unpack],
      environment: ["COPYFILE_DISABLE": "1"]
    )
  }
}
