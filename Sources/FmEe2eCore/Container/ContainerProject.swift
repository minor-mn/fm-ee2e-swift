import Foundation

/// プロジェクトに保存する、Apple Container の作成設定。
struct NativeContainerDefinition {
  let service: String
  let name: String
  let image: String
  let create: [String]
  let prepare: [[String]]
  let problem: String?
  var notes: [String] = []

  var json: [String: Any] {
    var value: [String: Any] = ["service": service, "name": name, "image": image, "create": create, "prepare": prepare, "notes": notes]
    if let problem { value["problem"] = problem }
    return value
  }

  /// コンテナ名（とサービス名）を変えた設定。create の --name も合わせる。
  func renamed(_ name: String, service: String? = nil) -> NativeContainerDefinition {
    var create = self.create
    if let index = create.firstIndex(of: "--name"), index + 1 < create.count { create[index + 1] = name }
    return NativeContainerDefinition(service: service ?? self.service, name: name, image: image, create: create, prepare: prepare, problem: problem, notes: notes)
  }

  /// メモリ・CPU を指定せずに作ると Apple Container の既定値になり、設定に残らない。作るときは必ずこの値を書く。
  static let defaultMemory = "1G"
  static let defaultCpus = "4"

  /// --memory・--cpus がなければ [defaultMemory]・[defaultCpus] を入れた設定を返す。作れない設定（[problem]）はそのまま。
  func withDefaults() throws -> NativeContainerDefinition {
    let needsMemory = !create.contains("--memory") && !create.contains("-m")
    let needsCpus = !create.contains("--cpus") && !create.contains("-c")
    guard problem == nil, needsMemory || needsCpus else { return self }
    var settings = ContainerSettings(self)
    if needsMemory { settings.memory = Self.defaultMemory }
    if needsCpus { settings.cpus = Self.defaultCpus }
    return try settings.applied(to: self)
  }
}

/// --volume の1件。[source] は Mac のパス（バインド）かボリューム名、[target] はコンテナの中のパス。
struct ContainerMount: Equatable {
  var source = ""
  var target = ""
  /// ro などの付け足し（コロン区切りの3つ目）。
  var options = ""

  init(source: String = "", target: String = "", options: String = "") {
    self.source = source; self.target = target; self.options = options
  }

  init(_ value: String) {
    let parts = value.components(separatedBy: ":")
    source = parts[0]
    target = parts.count > 1 ? parts[1] : ""
    options = parts.count > 2 ? parts[2...].joined(separator: ":") : ""
  }

  var isEmpty: Bool { [source, target, options].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
  var value: String { [source, target].joined(separator: ":") + (options.isEmpty ? "" : ":" + options) }
  /// 名前付きボリュームなら、その名前。
  var volume: String? { source.hasPrefix("/") ? nil : source }
}

/// A の設定窓で変えられる、作成設定の項目。ほかの引数（環境変数など）はそのまま残す。
struct ContainerSettings: Equatable {
  var image = ""
  var platform = ""
  var rosetta = false
  var cpus = ""
  var memory = ""
  /// --publish・--network の値。空白で区切って入力する（値に空白は入らない）。
  var ports: [String] = []
  var networks: [String] = []
  var mounts: [ContainerMount] = []

  private static let valueFlags = ["--platform", "--cpus", "--memory", "--publish", "--network", "--volume"]

  init(image: String = "", platform: String = "", rosetta: Bool = false, cpus: String = "", memory: String = "", ports: [String] = [], networks: [String] = [],
    mounts: [ContainerMount] = []) {
    self.image = image; self.platform = platform; self.rosetta = rosetta; self.cpus = cpus; self.memory = memory
    self.ports = ports; self.networks = networks; self.mounts = mounts
  }

  init(_ definition: NativeContainerDefinition) {
    image = definition.image
    let create = definition.create
    var index = 0
    while index < Self.imageIndex(definition) ?? create.count {
      let value = index + 1 < create.count ? create[index + 1] : ""
      switch create[index] {
      case "--platform": platform = value
      case "--cpus": cpus = value
      case "--memory": memory = value
      case "--publish": ports.append(value)
      case "--network": networks.append(value)
      case "--volume": mounts.append(ContainerMount(value))
      case "--rosetta": rosetta = true; index += 1; continue
      default: index += 1; continue
      }
      index += 2
    }
  }

  /// create の引数のうち、イメージの位置。イメージより後ろは、イメージに渡すコマンドの引数。
  static func imageIndex(_ definition: NativeContainerDefinition) -> Int? {
    definition.create.indices.dropFirst().first { definition.create[$0] == definition.image && !valueFlags.contains(definition.create[$0 - 1]) }
  }

  /// 変えた項目だけを create・build に入れ直した設定を返す。
  func applied(to definition: NativeContainerDefinition) throws -> NativeContainerDefinition {
    let image = self.image.trimmingCharacters(in: .whitespaces)
    guard !image.isEmpty, !image.hasPrefix("-"), let imageAt = Self.imageIndex(definition) else {
      throw AppError(tr("container.invalid_saved_config", ["file": definition.service]))
    }
    var options: [String] = []
    var index = 1
    while index < imageAt {
      let flag = definition.create[index]
      if flag == "--rosetta" { index += 1; continue }
      if Self.valueFlags.contains(flag) { index += 2; continue }
      options.append(flag)
      index += 1
    }
    func value(_ flag: String, _ text: String) -> [String] {
      let text = text.trimmingCharacters(in: .whitespaces)
      return text.isEmpty ? [] : [flag, text]
    }
    options += value("--platform", platform) + (rosetta ? ["--rosetta"] : []) + value("--cpus", cpus) + value("--memory", memory)
    options += ports.flatMap { value("--publish", $0) } + networks.flatMap { value("--network", $0) }
    // マウントは、Mac 側を絶対パス（~ は展開する）かボリューム名、コンテナ側を絶対パスにする。
    var newVolumes: [String] = []
    for mount in mounts where !mount.isEmpty {
      var mount = ContainerMount(source: mount.source.trimmingCharacters(in: .whitespaces), target: mount.target.trimmingCharacters(in: .whitespaces),
        options: mount.options.trimmingCharacters(in: .whitespaces))
      if mount.source.hasPrefix("~") { mount.source = expandHome(mount.source, homeDir) }
      let volumeName = mount.source.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil
      guard mount.target.hasPrefix("/"), mount.source.hasPrefix("/") || volumeName, ![mount.source, mount.target].contains(where: { $0.contains(":") }) else {
        throw AppError(tr("container.settings.invalid_mount", ["mount": mount.value]))
      }
      options += ["--volume", mount.value]
      if let volume = mount.volume, !definition.prepare.contains(["volume", "create", volume]) { newVolumes.append(volume) }
    }
    // ビルドするイメージは、タグとプラットフォームも合わせる。
    let prepare = definition.prepare.map { step -> [String] in
      guard step.first == "build" else { return step }
      var result: [String] = []
      var index = 0
      while index < step.count {
        if step[index] == "--platform", index + 1 < step.count { index += 2; continue }
        if step[index] == "--tag", index + 1 < step.count, step[index + 1] == definition.image {
          result += ["--tag", image]; index += 2; continue
        }
        result.append(step[index])
        index += 1
      }
      return result.prefix(1) + value("--platform", platform) + result.dropFirst()
    }
    // 新しく使う名前付きボリュームは、作成の準備で作る（作成済みなら飛ばし、新しく作ったら初期化する）。
    let volumes = Array(Set(newVolumes)).sorted().map { ["volume", "create", $0] }
    return NativeContainerDefinition(service: definition.service, name: definition.name, image: image,
      create: ["create"] + options + [image] + definition.create[(imageAt + 1)...], prepare: prepare + volumes, problem: definition.problem, notes: definition.notes)
  }
}

struct NativeContainerProject {
  let root: String
  let definitions: [NativeContainerDefinition]
  var awsProfile: String? = nil

  static func settings(_ root: String) -> String { p.join(root, ".fm-ee2e", "project.json5") }

  /// 子フォルダーでも同じ設定を使う。独自設定がある子プロジェクトはそちらを優先する。
  static func findRoot(_ directory: String) -> String? {
    var directory = p.absolute(directory)
    while true {
      if FileManager.default.fileExists(atPath: settings(directory)) || !ComposeProject.discover(directory, environment: [:]).isEmpty { return directory }
      let parent = p.dirname(directory)
      if parent == directory { return nil }
      directory = parent
    }
  }

  static func read(_ root: String) throws -> NativeContainerProject {
    func object(_ path: String) throws -> [String: Any] {
      guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)), options: [.json5Allowed]) as? [String: Any] else {
        throw AppError(tr("container.invalid_saved_config", ["file": path]))
      }
      return value
    }
    let project = try object(settings(root))
    guard let files = project["containers"] as? [String] else { throw AppError(tr("container.invalid_saved_config", ["file": settings(root)])) }
    let definitions = try files.map { file -> NativeContainerDefinition in
      guard p.basename(file) == file, file.hasSuffix(".json5") else { throw AppError(tr("container.invalid_saved_config", ["file": file])) }
      let path = p.join(root, ".fm-ee2e", "containers", file)
      let value = try object(path)
      guard let service = value["service"] as? String, let name = value["name"] as? String,
        let image = value["image"] as? String, let create = value["create"] as? [String], let prepare = value["prepare"] as? [[String]]
      else { throw AppError(tr("container.invalid_saved_config", ["file": path])) }
      let problem = value["problem"] as? String
      guard problem != nil || (create.first == "create" && create.indices.contains(2) && create[1] == "--name" && create[2] == name),
        prepare.allSatisfy({ $0.first == "build" || $0.starts(with: ["network", "create"]) || $0.starts(with: ["volume", "create"]) })
      else { throw AppError(tr("container.invalid_saved_config", ["file": path])) }
      guard service.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else { throw AppError(tr("container.invalid_saved_config", ["file": path])) }
      return NativeContainerDefinition(service: service, name: name, image: image, create: create, prepare: prepare, problem: problem, notes: value["notes"] as? [String] ?? [])
    }
    guard Set(definitions.map(\.name)).count == definitions.count else { throw AppError(tr("container.duplicate_names")) }
    return NativeContainerProject(root: root, definitions: definitions, awsProfile: project["aws_profile"] as? String)
  }

  /// 初回だけ Compose を読み、各コンテナの独立した設定に変換する。依存先は作成・起動しない。
  static func importDraft(_ source: ComposeProject) throws -> NativeContainerProject {
    let source = try ComposeProject.load(source.files)
    let definitions = try source.services.keys.sorted().map { service -> NativeContainerDefinition in
      guard service.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else {
        throw AppError(tr("container.invalid_saved_config", ["file": service]))
      }
      let name = source.containerName(service)
      let image = source.services[service]!["image"] as? String ?? "\(source.name)-\(service):latest"
      do {
        let plan = try source.plan(service)
        return try NativeContainerDefinition(service: service, name: name, image: image, create: plan.create,
          prepare: plan.prepare, problem: nil, notes: plan.warnings).withDefaults()
      } catch {
        return NativeContainerDefinition(service: service, name: name, image: image, create: [], prepare: [], problem: errorMessage(error))
      }
    }
    return NativeContainerProject(root: source.directory, definitions: definitions)
  }

  func file(_ definition: NativeContainerDefinition) -> String { p.join(root, ".fm-ee2e", "containers", "\(definition.service).json5") }

  func save() throws {
    let directory = p.join(root, ".fm-ee2e", "containers")
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    for definition in definitions where !FileManager.default.fileExists(atPath: file(definition)) {
      try Self.write(definition.json, file(definition))
    }
    var project: [String: Any] = ["containers": definitions.map { "\($0.service).json5" }]
    if let awsProfile { project["aws_profile"] = awsProfile }
    try Self.write(project, Self.settings(root))
  }

  /// [definition] を同じサービスの設定と置き換えて保存する（そのサービスのファイルは書き直す）。
  func replacing(_ definition: NativeContainerDefinition) throws -> NativeContainerProject {
    let project = NativeContainerProject(root: root, definitions: definitions.map { $0.service == definition.service ? definition : $0 }, awsProfile: awsProfile)
    try project.save()
    try Self.write(definition.json, file(definition))
    return project
  }

  /// [definition] を足して保存する（そのサービスのファイルは書き直す）。
  func adding(_ definition: NativeContainerDefinition) throws -> NativeContainerProject {
    let project = NativeContainerProject(root: root, definitions: definitions + [definition], awsProfile: awsProfile)
    try project.save()
    try Self.write(definition.json, file(definition))
    return project
  }

  private static func write(_ value: [String: Any], _ file: String) throws {
    let data = Data(json5Text(value).utf8)
    try data.write(to: URL(fileURLWithPath: file), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
  }

  /// 作成に必要な container コマンドを順に返す。作成済みの network・volume は飛ばし、新しく作る volume は初期化する。
  func createSteps(_ definition: NativeContainerDefinition, client: ContainerClient) async throws -> [[String]] {
    if let problem = definition.problem { throw AppError(problem) }
    var steps: [[String]] = []
    var createdVolumes: [String] = []
    for arguments in definition.prepare {
      if arguments.starts(with: ["network", "create"]) || arguments.starts(with: ["volume", "create"]), let name = arguments.last {
        let result = try await client.checked([arguments[0], "list", "--format", "json"])
        guard let rows = try JSONSerialization.jsonObject(with: result.stdoutData) as? [[String: Any]] else { throw AppError(tr("container.invalid_list")) }
        if rows.contains(where: { ($0["id"] as? String ?? $0["name"] as? String ?? ($0["configuration"] as? [String: Any])?["name"] as? String) == name }) { continue }
        if arguments[0] == "volume" { createdVolumes.append(name) }
      }
      steps.append(arguments)
    }
    for (volume, target) in Self.volumeMounts(definition.create) where createdVolumes.contains(volume) {
      steps.append(Self.initializeVolumeArgs(definition, volume: volume, target: target))
    }
    return steps + [definition.create]
  }

  /// create の引数にある名前付きボリュームとマウント先。バインド（絶対パス）は含めない。
  static func volumeMounts(_ create: [String]) -> [(volume: String, target: String)] {
    zip(create, create.dropFirst()).compactMap { flag, value in
      guard flag == "--volume" || flag == "-v", !value.hasPrefix("/") else { return nil }
      let parts = value.components(separatedBy: ":")
      guard parts.count >= 2, parts[1].hasPrefix("/") else { return nil }
      return (parts[0], parts[1])
    }
  }

  /// Docker と同じく、新しいボリュームにイメージのマウント先の中身を持ち主・権限ごと一度だけ写す。
  /// Apple Container の新しいボリュームにある lost+found は、空のフォルダーを前提にするイメージ（MySQL など）のために消す。
  static func initializeVolumeArgs(_ definition: NativeContainerDefinition, volume: String, target: String) -> [String] {
    let mount = "/fm-ee2e-volume"
    let script = """
      set -e
      rmdir \(mount)/lost+found 2>/dev/null || true
      if [ -d "$1" ]; then
        cp -a "$1"/. \(mount)/
        chown "$(stat -c %u:%g "$1")" \(mount)
        chmod "$(stat -c %a "$1")" \(mount)
      fi
      """
    var platform: [String] = []
    for (index, argument) in definition.create.enumerated() {
      if argument == "--platform", index + 1 < definition.create.count { platform += [argument, definition.create[index + 1]] }
      if argument == "--rosetta" { platform.append(argument) }
    }
    return ["run", "--rm", "--user", "0:0"] + platform + ["--volume", "\(volume):\(mount)", "--entrypoint", "/bin/sh", definition.image, "-c", script, "sh", target]
  }
}
