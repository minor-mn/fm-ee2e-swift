import Foundation
import Yams

/// 1つのサービスを Apple Container で作るためのコマンド。準備（build・network・volume の作成）と create。
struct ComposePlan {
  var prepare: [[String]] = []
  var create: [String] = []
  var warnings: [String] = []
}

/// Compose の対応範囲を、Apple Container の設定に変換する。初回の取り込みだけで使い、Compose 自体は実行しない。
struct ComposeProject {
  let directory: String
  let files: [String]
  let name: String
  let services: [String: [String: Any]]
  let volumes: [String: Any]
  let networks: [String: Any]
  let environment: [String: String]

  static func discover(_ directory: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
    if let selected = environment["COMPOSE_FILE"], !selected.isEmpty {
      return selected.components(separatedBy: ":").map { absolute($0, directory) }
    }
    // Compose の標準のファイル名だけを探す。ほかの名前は F で選ぶか COMPOSE_FILE で指定する。
    let bases = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"]
    guard let base = bases.first(where: { FileManager.default.fileExists(atPath: p.join(directory, $0)) }) else { return [] }
    let overrides = base.hasPrefix("compose.") ? ["compose.override.yaml", "compose.override.yml"] : ["docker-compose.override.yml", "docker-compose.override.yaml"]
    let extra = overrides.first { FileManager.default.fileExists(atPath: p.join(directory, $0)) }
    return ([base] + (extra.map { [$0] } ?? [])).map { p.join(directory, $0) }
  }

  static func load(_ files: [String], environment host: [String: String] = ProcessInfo.processInfo.environment, listingOnly: Bool = false) throws -> ComposeProject {
    guard let first = files.first else { throw AppError(tr("container.no_compose")) }
    let directory = p.dirname(p.absolute(first))
    var env: [String: String] = [:]
    let envFile = p.join(directory, ".env")
    if FileManager.default.fileExists(atPath: envFile) {
      if listingOnly { env = (try? composeEnvironment(String(contentsOfFile: envFile, encoding: .utf8))) ?? [:] }
      else { env = try composeEnvironment(String(contentsOfFile: envFile, encoding: .utf8)) }
    }
    env.merge(host) { _, new in new }
    var root: [String: Any] = [:]
    for file in files {
      let path = absolute(file, directory)
      guard var document = try Yams.load(yaml: String(contentsOfFile: path, encoding: .utf8)) as? [String: Any] else {
        throw AppError(tr("container.invalid_compose", ["file": p.basename(path)]))
      }
      if listingOnly {
        var catalog: [String: Any] = [:]
        catalog["name"] = document["name"]
        if let services = document["services"] as? [String: Any] {
          catalog["services"] = services.mapValues { value -> [String: Any] in
            guard let fields = value as? [String: Any], let name = fields["container_name"] else { return [:] }
            return ["container_name": name]
          }
        }
        document = catalog
      }
      root = mergeCompose(root, try interpolateCompose(document, env) as! [String: Any])
    }
    // Apple Container に置き換えられない設定（configs・secrets など）は使わない。
    guard let services = root["services"] as? [String: [String: Any]], !services.isEmpty else {
      throw AppError(tr("container.no_services"))
    }
    let name = env["COMPOSE_PROJECT_NAME"] ?? root["name"] as? String ?? p.basename(directory).lowercased()
    guard !name.isEmpty, name.range(of: #"^[a-z0-9][a-z0-9_-]*$"#, options: .regularExpression) != nil else {
      throw AppError(tr("container.invalid_project_name"))
    }
    let project = ComposeProject(directory: directory, files: files, name: name, services: services,
      volumes: try mapping(root["volumes"], "volumes"), networks: try mapping(root["networks"], "networks"), environment: env)
    let names = services.keys.map { project.containerName($0) }
    guard Set(names).count == names.count, names.allSatisfy({ $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil }) else {
      throw AppError(tr("container.duplicate_names"))
    }
    return project
  }

  /// コンテナ名は Mac 全体で1つの名前空間なので、container_name がなければプロジェクト名を付ける（Docker Compose と同じ考え方）。
  /// ほかのコンテナからは、これまでどおりサービス名（ネットワークの別名）で引ける。
  func containerName(_ service: String) -> String { services[service]?["container_name"] as? String ?? "\(name)-\(service)" }

  /// 1つのサービスの設定を変換する。依存先は作らない。Docker と互換のない設定・解釈できない書き方は使わずに進める。
  /// external の不足など、作っても動かないものだけ失敗させる。
  /// [networks]・[volumes] は作成済みとみなす名前。
  func plan(_ service: String, networks knownNetworks: Set<String> = [], volumes knownVolumes: Set<String> = []) throws -> ComposePlan {
    let values = services[service]!
    var plan = ComposePlan()
    var networkNames = knownNetworks
    var volumeNames = knownVolumes
    let domain = "\(name).container"
    func step(_ args: [String]) { plan.prepare.append(args) }
    let container = containerName(service)
    // restart・privileged・healthcheck など、ここで扱わない設定は使わない。
    var args = ["create", "--name", container, "--label", "fm-ee2e.compose.project=\(name)", "--label", "fm-ee2e.compose.service=\(service)"]
    let platform = (values["platform"] as? String)?.replacingOccurrences(of: "x86_64", with: "amd64")
    if let platform {
      args += ["--platform", platform]
      if platform == "linux/amd64" { args.append("--rosetta") }
    }
    var image = values["image"] as? String
    if let build = values["build"], !(build is NSNull) {
      let config = build as? String != nil ? ["context": build] : try Self.mapping(build, "build")
      image = image ?? "\(name)-\(service):latest"
      var buildArgs = ["build", "--tag", image!]
      let context = Self.absolute(config["context"] as? String ?? ".", directory)
      if let dockerfile = config["dockerfile"] as? String { buildArgs += ["--file", Self.absolute(dockerfile, context)] }
      if let platform { buildArgs += ["--platform", platform] }
      if let target = config["target"] as? String { buildArgs += ["--target", target] }
      for value in try Self.keyValues(config["args"], "build.args") { buildArgs += ["--build-arg", value] }
      step(buildArgs + [context])
    }
    guard let image, !image.isEmpty, !image.hasPrefix("-") else { throw AppError(tr("container.no_image", ["service": service])) }
    for (key, flag) in [("working_dir", "--workdir"), ("user", "--user"), ("shm_size", "--shm-size")] {
      if let value = values[key], !(value is NSNull) { args += [flag, Self.scalar(value)] }
    }
    for (key, flag) in [("tty", "--tty"), ("stdin_open", "--interactive"), ("read_only", "--read-only"), ("init", "--init")] {
      if values[key] as? Bool == true { args.append(flag) }
    }
    if let hostname = values["hostname"] as? String {
      plan.warnings.append(tr("container.hostname_alias", ["service": service, "hostname": hostname]))
    }
    for (key, flag) in [("environment", "--env"), ("labels", "--label")] {
      for value in try Self.keyValues(values[key], key) { args += [flag, value] }
    }
    for file in try Self.oneOrMany(values["env_file"], "env_file") {
      let path = Self.absolute(file, directory)
      guard FileManager.default.fileExists(atPath: path) else { throw AppError(tr("container.missing_file", ["file": path])) }
      args += ["--env-file", path]
    }
    for (key, flag) in [("cap_add", "--cap-add"), ("cap_drop", "--cap-drop")] {
      for value in try Self.strings(values[key], key) { args += [flag, value] }
    }
    for (key, value) in try Self.mapping(values["ulimits"], "ulimits").sorted(by: { $0.key < $1.key }) {
      if let limits = value as? [String: Any], let soft = limits["soft"], let hard = limits["hard"] {
        args += ["--ulimit", "\(key)=\(Self.scalar(soft)):\(Self.scalar(hard))"]
      } else if value is NSNumber { args += ["--ulimit", "\(key)=\(Self.scalar(value))"] }
    }
    for port in try Self.sequence(values["ports"], "ports") {
      if let spec = port as? [String: Any], let target = spec["target"], let published = spec["published"] {
        let host = (spec["host_ip"] as? String).map { "\($0):" } ?? ""
        args += ["--publish", "\(host)\(Self.scalar(published)):\(Self.scalar(target))/\(spec["protocol"] as? String ?? "tcp")"]
      } else if port is String || port is NSNumber { args += ["--publish", Self.scalar(port)] }
    }
    for volume in try Self.sequence(values["volumes"], "volumes") {
      guard let mount = try mount(volume) else { continue }
      if let resource = mount.resource {
        if !volumeNames.contains(resource.name) {
          if resource.external { throw AppError(tr("container.missing_external", ["name": resource.name])) }
          step(["volume", "create", resource.name])
          volumeNames.insert(resource.name)
        }
      }
      args += ["--volume", mount.spec]
    }
    let serviceNetworks = try networkAttachments(service)
    // 管理名は <コンテナ名>.container、サービスの別名は <サービス名>.<プロジェクト名>.container。
    // 検索ドメインを付け、コンテナ内では従来どおり redis などの短い名前も使える。
    args += ["--dns-domain", "container", "--dns-search", domain, "--dns-search", "container"]
    for (key, aliases) in serviceNetworks {
      let resource = try resource(key, in: networks)
      if !networkNames.contains(resource.name) {
        if resource.external { throw AppError(tr("container.missing_external", ["name": resource.name])) }
        let config = try Self.mapping(networks[key], "networks.\(key)")
        step(["network", "create"] + (config["internal"] as? Bool == true ? ["--internal"] : []) + [resource.name])
        networkNames.insert(resource.name)
      }
      let dnsAliases = aliases.map { $0.contains(".") ? $0 : "\($0).\(domain)" }.filter { !$0.contains(",") && !$0.isEmpty }
      args += ["--network", resource.name + Array(Set(dnsAliases)).sorted().map { ",alias=\($0)" }.joined()]
    }
    // Apple Container の --entrypoint は実行ファイル1つだけなので、残りの語はコマンドの前に付ける（Docker と同じ順で動く）。
    var entrypointArgs: [String] = []
    if let entrypoint = values["entrypoint"], !(entrypoint is NSNull), let first = try Self.command(entrypoint).first {
      args += ["--entrypoint", first]
      entrypointArgs = Array(try Self.command(entrypoint).dropFirst())
    }
    plan.create = args + [image] + entrypointArgs + (try Self.command(values["command"]))
    return plan
  }

  private func resource(_ key: String, in definitions: [String: Any]) throws -> (name: String, external: Bool) {
    let options = try Self.mapping(definitions[key], key)
    let externalMap = options["external"] as? [String: Any]
    let external = options["external"] as? Bool == true || externalMap != nil
    let resolved = options["name"] as? String ?? externalMap?["name"] as? String ?? (external ? key : "\(name)-\(key)")
    return (resolved, external)
  }

  /// 1つのマウント。Apple Container で使えない書き方（tmpfs・docker.sock・相対のコンテナ側など）は nil で使わない。
  private func mount(_ raw: Any) throws -> (spec: String, resource: (name: String, external: Bool)?)? {
    let source: String
    let target: String
    var readOnly = false
    var type: String?
    if let text = raw as? String {
      let parts = text.components(separatedBy: ":")
      guard parts.count == 2 || parts.count == 3 else { return nil }
      source = parts[0]; target = parts[1]
      readOnly = parts.count == 3 && parts[2].components(separatedBy: ",").contains("ro")
    } else {
      let options = try Self.mapping(raw, "volumes")
      guard let src = options["source"] as? String, let dest = options["target"] as? String else { return nil }
      source = src; target = dest; type = options["type"] as? String; readOnly = options["read_only"] as? Bool == true
    }
    guard target.hasPrefix("/"), !source.isEmpty, !source.contains(":"), !target.contains(":"), !source.hasSuffix("docker.sock") else { return nil }
    if let type, !["bind", "volume"].contains(type) { return nil }
    let bind = type == "bind" || source.hasPrefix("/") || source.hasPrefix(".") || source.hasPrefix("~")
    if bind {
      let path = Self.absolute(expandHome(source, environment["HOME"] ?? homeDir), directory)
      guard FileManager.default.fileExists(atPath: path) else { throw AppError(tr("container.missing_file", ["file": path])) }
      return ("\(path):\(target)\(readOnly ? ":ro" : "")", nil)
    }
    guard volumes[source] != nil else { throw AppError(tr("container.missing_volume", ["name": source])) }
    let volume = try resource(source, in: volumes)
    return ("\(volume.name):\(target)\(readOnly ? ":ro" : "")", volume)
  }

  private func networkAttachments(_ service: String) throws -> [(String, [String])] {
    let values = services[service]!
    let raw = values["networks"]
    let configs = raw as? [String: Any]
    let keys = try configs?.keys.sorted() ?? Self.strings(raw, "networks")
    var aliases = [service]
    if let hostname = values["hostname"] as? String { aliases.append(hostname) }
    for (_, consumer) in services {
      for link in try Self.strings(consumer["links"], "links") {
        let parts = link.components(separatedBy: ":")
        if parts.first == service, parts.count == 2 { aliases.append(parts[1]) }
      }
    }
    // 定義のないネットワークは使わない。別名以外のネットワークの設定（ipv4_address など）も使わない。
    let attached = (keys.isEmpty ? ["default"] : keys).filter { $0 == "default" || networks[$0] != nil }
    return try (attached.isEmpty ? ["default"] : attached).map { key in
      let config = try Self.mapping(configs?[key], "networks.\(key)")
      return (key, aliases + (try Self.strings(config["aliases"], "networks.aliases")))
    }
  }

  private static func absolute(_ path: String, _ directory: String) -> String { p.normalize(p.isAbsolute(path) ? path : p.join(directory, path)) }
  // 形の違う値（マップのはずが文字列など）は、ないものとして扱う。
  private static func mapping(_ value: Any?, _ key: String) throws -> [String: Any] { value as? [String: Any] ?? [:] }
  private static func sequence(_ value: Any?, _ key: String) throws -> [Any] { value as? [Any] ?? [] }
  private static func strings(_ value: Any?, _ key: String) throws -> [String] {
    try sequence(value, key).compactMap { $0 as? String }
  }
  private static func oneOrMany(_ value: Any?, _ key: String) throws -> [String] {
    if let value = value as? String { return [value] }
    return try strings(value, key)
  }
  private static func scalar(_ value: Any) -> String {
    if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
    return String(describing: value)
  }
  private static func keyValues(_ value: Any?, _ key: String) throws -> [String] {
    if let map = value as? [String: Any] {
      return map.keys.sorted().compactMap { name in
        let value = map[name]!
        if value is NSNull { return name }
        guard value is String || value is NSNumber else { return nil }
        return "\(name)=\(scalar(value))"
      }
    }
    return try strings(value, key)
  }
  private static func command(_ value: Any?) throws -> [String] {
    guard let value, !(value is NSNull) else { return [] }
    if let value = value as? String { return try splitComposeCommand(value) }
    return try strings(value, "command")
  }
}

/// マップを再帰的に重ね、environment はキー、volumes はマウント先で上書きする。
func mergeCompose(_ base: [String: Any], _ override: [String: Any]) -> [String: Any] {
  var result = base
  for (key, value) in override {
    if let before = result[key] as? [String: Any], let after = value as? [String: Any] {
      result[key] = mergeCompose(before, after)
    } else if key == "environment", let before = result[key] {
      func map(_ raw: Any) -> [String: Any] {
        if let map = raw as? [String: Any] { return map }
        var map: [String: Any] = [:]
        for entry in raw as? [String] ?? [] {
          let parts = entry.components(separatedBy: "=")
          map[parts[0]] = parts.count > 1 ? parts.dropFirst().joined(separator: "=") : NSNull()
        }
        return map
      }
      result[key] = map(before).merging(map(value)) { _, new in new }
    } else if let before = result[key] as? [Any], let after = value as? [Any], !["command", "entrypoint"].contains(key) {
      func identity(_ raw: Any) -> String {
        if key == "volumes" {
          if let map = raw as? [String: Any] { return map["target"] as? String ?? String(describing: raw) }
          let parts = (raw as? String ?? "").components(separatedBy: ":")
          return parts.count > 1 ? parts[1] : parts[0]
        }
        return String(describing: raw)
      }
      let replaced = Set(after.map(identity))
      result[key] = before.filter { !replaced.contains(identity($0)) } + after
    } else { result[key] = value }
  }
  return result
}

private func interpolateCompose(_ value: Any, _ environment: [String: String]) throws -> Any {
  if let text = value as? String { return try expandComposeVariables(text, environment) }
  if let map = value as? [String: Any] { return try map.mapValues { try interpolateCompose($0, environment) } }
  if let list = value as? [Any] { return try list.map { try interpolateCompose($0, environment) } }
  return value
}

func expandComposeVariables(_ text: String, _ environment: [String: String]) throws -> String {
  let characters = Array(text)
  var i = 0
  var output = ""
  while i < characters.count {
    guard characters[i] == "$", i + 1 < characters.count else { output.append(characters[i]); i += 1; continue }
    if characters[i + 1] == "$" { output.append("$"); i += 2; continue }
    let braced = characters[i + 1] == "{"
    var end = i + (braced ? 2 : 1)
    let start = end
    while end < characters.count && (characters[end].isLetter || characters[end].isNumber || characters[end] == "_") { end += 1 }
    if start == end { output.append("$"); i += 1; continue }
    let name = String(characters[start..<end])
    var suffix = ""
    if braced {
      let suffixStart = end
      var depth = 0
      while end < characters.count {
        if characters[end] == "{" { depth += 1 }
        if characters[end] == "}" { if depth == 0 { break }; depth -= 1 }
        end += 1
      }
      guard end < characters.count else { throw AppError(tr("container.invalid_variable", ["name": name])) }
      suffix = String(characters[suffixStart..<end])
      end += 1
    }
    let value = environment[name]
    let operators = [":-", ":?", ":+", "-", "?", "+"]
    if let op = operators.first(where: { suffix.hasPrefix($0) }) {
      let missing = value == nil || (op.hasPrefix(":") && value!.isEmpty)
      let fallback = String(suffix.dropFirst(op.count))
      if op.hasSuffix("?") && missing { throw AppError(tr("container.required_variable", ["name": name])) }
      if op.hasSuffix("+") { output += missing ? "" : try expandComposeVariables(fallback, environment) }
      else { output += missing ? try expandComposeVariables(fallback, environment) : value! }
    } else if !suffix.isEmpty { throw AppError(tr("container.invalid_variable", ["name": name])) }
    else { output += value ?? "" }
    i = end
  }
  return output
}

func composeEnvironment(_ text: String) throws -> [String: String] {
  var result: [String: String] = [:]
  for raw in text.components(separatedBy: .newlines) {
    var line = raw.trimmingCharacters(in: .whitespaces)
    if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
    if line.isEmpty || line.hasPrefix("#") { continue }
    guard let equals = line.firstIndex(of: "=") else { throw AppError(tr("container.invalid_env")) }
    let key = line[..<equals].trimmingCharacters(in: .whitespaces)
    var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
    if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) { value = String(value.dropFirst().dropLast()) }
    else if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces) }
    result[key] = value
  }
  return result
}

/// Compose の文字列 command はシェルに評価させず、引用符を尊重して argv に分ける。
func splitComposeCommand(_ text: String) throws -> [String] {
  var words: [String] = []
  var word = ""
  var quote: Character?
  var escaped = false
  var started = false
  for character in text {
    if escaped { word.append(character); escaped = false; started = true }
    else if character == "\\" && quote != "'" { escaped = true; started = true }
    else if character == quote { quote = nil }
    else if quote == nil && (character == "'" || character == "\"") { quote = character; started = true }
    else if quote == nil && character.isWhitespace {
      if started { words.append(word); word = ""; started = false }
    } else { word.append(character); started = true }
  }
  guard quote == nil && !escaped else { throw AppError(tr("container.invalid_command")) }
  if started { words.append(word) }
  return words
}
