import Foundation

struct ContainerTarget {
  let name: String
  let service: String?
  let status: String
  var details = ContainerDetails()
  var running: Bool { status.lowercased() == "running" }
}

/// 一覧のブロックの見出し（カーソルは乗らない）。
struct ContainerSection {
  let title: String
}

/// 今のフォルダーにある Dockerfile。Enter で、そこから作るコンテナの設定を作り、ビルドして作成する。
struct DockerfileTarget {
  let path: String
  /// ビルドしてつけるイメージの名前（フォルダー名から決める）。
  let image: String
  let built: Bool

  /// Dockerfile、Dockerfile.<名前>、<名前>.Dockerfile。
  static func isDockerfile(_ name: String) -> Bool {
    let lower = name.lowercased()
    return lower == "dockerfile" || lower.hasPrefix("dockerfile.") || lower.hasSuffix(".dockerfile")
  }

  /// フォルダー名を土台に、Dockerfile.dev なら -dev、api.Dockerfile なら -api を付けた名前（タグは latest）。
  static func imageName(_ path: String) -> String {
    func clean(_ text: String) -> String {
      let mapped = text.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "-" }
      return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
    }
    let base = clean(p.basename(p.dirname(path)))
    let file = p.basename(path)
    let lower = file.lowercased()
    let suffix = lower == "dockerfile" ? "" : lower.hasPrefix("dockerfile.") ? String(file.dropFirst(11)) : String(file.dropLast(11))
    let name = [base.isEmpty ? "image" : base, clean(suffix)].filter { !$0.isEmpty }.joined(separator: "-")
    return name + ":latest"
  }

  /// EXPOSE のポートを、同じ番号で公開する指定にする（変数を使ったものは除く）。
  static func exposedPorts(_ text: String) -> [String] {
    var ports: [String] = []
    for line in text.components(separatedBy: .newlines) {
      let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
      guard words.first?.uppercased() == "EXPOSE" else { continue }
      for word in words.dropFirst() where !word.contains("$") {
        let parts = word.split(separator: "/", maxSplits: 1).map(String.init)
        guard let port = Int(parts[0]) else { continue }
        let value = "\(port):\(port)" + (parts.count > 1 && parts[1].lowercased() != "tcp" ? "/" + parts[1].lowercased() : "")
        if !ports.contains(value) { ports.append(value) }
      }
    }
    return ports
  }
}

/// SSH の一覧・ファイル操作・圧縮・補完を共有し、接続先の選択と転送だけ差し替える。
final class ContainerPane: SshPane {
  let client: ContainerClient
  var localDirectory: () -> String = { homeDir }
  private(set) var project: ComposeProject?
  private var nativeProject: NativeContainerProject?
  private var selectedFiles: [String]?
  private var filesDirectory: String?
  private var notice: [String]?
  private var serviceStopped = false
  /// 一覧をネットワークごとに並べる（F12 の by Network）。その間の F12 の先頭は by Status で、選ぶと元の並びに戻る。
  private(set) var byNetwork = false
  private var widestDetail = 0

  init(_ app: App, client: ContainerClient = ContainerClient()) {
    self.client = client
    super.init(app)
  }

  override var themeKey: ThemeKey { .container }
  override var accent: Rgb { colors.accent ?? colors.orange }
  override var selection: Rgb { colors.selection ?? colors.orangeDark }
  override var title: String { ssh.map { "Container \($0.host)" } ?? "Container" }
  override var location: String { ssh == nil ? localDirectory() : super.location }
  override var placeholder: [String]? { notice }
  override var usageLabels: [String] { ssh == nil ? [] : super.usageLabels }

  /// 接続前は、カーソルのコンテナの設定を上の帯の2行に出す。値のない項目は出さない。
  override var headerFields: [[(String, String)]]? {
    guard ssh == nil, notice == nil else { return nil }
    if let dockerfile = current?.data as? DockerfileTarget {
      return [[(tr("container.info.image"), dockerfile.image)], [(tr("container.info.dockerfile"), dockerfile.path)]]
    }
    guard let target = current?.data as? ContainerTarget else { return nil }
    let details = target.details
    func field(_ key: String, _ value: String?) -> [(String, String)] {
      guard let value, !value.isEmpty else { return [] }
      return [(tr("container.info.\(key)"), value)]
    }
    let platform = details.platform.map { details.rosetta ? "\($0) (Rosetta)" : $0 }
    return [
      field("image", details.image) + field("platform", platform) + field("cpus", details.cpus) + field("memory", details.memory),
      field("address", details.addresses.joined(separator: ", ")) + field("ports", details.ports.joined(separator: ", "))
        + field("networks", details.networks.joined(separator: ", ")),
    ]
  }
  override var canMark: Bool { ssh == nil || super.canMark }
  override func markable(_ entry: Entry) -> Bool { entry.data is ContainerTarget || (!(entry.data is ContainerSection) && super.markable(entry)) }
  override func selectable(_ entry: Entry) -> Bool { !(entry.data is ContainerSection) }
  override var folderKey: String { ssh == nil ? "container-list" : super.folderKey }
  override func keyOf(_ entry: Entry) -> String {
    if let target = entry.data as? ContainerTarget { return "container:\(target.name)" }
    return super.keyOf(entry)
  }
  override var keyOperations: [String: Operation] {
    ssh == nil ? ["char:c": .create, "f1": .create, "f2": .extract, "f3": .shell, "f4": .delete, "f5": .chmod, "f12": .logs] : [:]
  }

  var targetStatuses: Set<String> {
    Set(targetMarks.compactMap { ($0.entry.data as? ContainerTarget)?.status.lowercased() })
  }

  func canPerformContainerAction(_ action: String) -> Bool {
    guard ssh == nil && ready else { return false }
    guard targetStatuses.count == 1 else { return false }
    switch action {
    case "create": return targetStatuses.contains("missing")
    case "start", "delete": return targetStatuses.contains("stopped")
    case "stop": return targetStatuses.contains("running")
    default: return false
    }
  }

  /// F12 は、カーソルがコンテナ（未作成のものを含む）の上にあるときだけ。
  var canShowLogs: Bool { ssh == nil && ready && current?.data is ContainerTarget }

  /// カーソルのコンテナのログを選んで、画面全体の端末で見せる（F12）。終わったあとも ↑↓ PgUp PgDn でさかのぼれる。
  /// 未作成のコンテナには自分のログがないので、Apple Container のサービスのログだけを選べる。
  func showLogs() async {
    guard canShowLogs, let target = current?.data as? ContainerTarget else { return }
    var choices: [(String, [String])] = [(tr(byNetwork ? "container.logs.by_status" : "container.logs.by_network"), [])]
    if target.status != "missing" {
      choices.append((tr("container.logs.output"), ["logs", target.name]))
      choices.append((tr("container.logs.boot"), ["logs", "--boot", target.name]))
    }
    choices.append((tr("container.logs.system"), ["system", "logs"]))
    guard let index = await app.askChoice(tr("container.logs.title", ["name": target.name]), choices.map(\.0)) else { return }
    let args = choices[index].1
    if args.isEmpty {
      byNetwork.toggle()
      resetCursor()
      await load()
      return
    }
    await runInTerminal(app, "\(target.name) $ container \(args.joined(separator: " "))", client.executable, args, frame: .page)
  }

  /// ネットワークごとに、「名前 - サブネット」を見出しにして、つながっているコンテナ（止まっているものも含む）を並べる。
  /// 複数のネットワークにつながっているコンテナは、それぞれの見出しの下に出す。左の名前はコンテナ名。
  private func networkEntries(_ containers: [ContainerInfo]) async throws -> [Entry] {
    let services = Dictionary((nativeProject?.definitions ?? []).map { ($0.name, $0.service) }, uniquingKeysWith: { first, _ in first })
    var entries: [Entry] = []
    for network in try await client.networks() {
      let members = containers.filter { $0.details.networks.contains(network.name) }.sorted { $0.name < $1.name }
      guard !members.isEmpty else { continue }
      let title = network.subnet.isEmpty ? network.name : "\(network.name) - \(network.subnet)"
      entries.append(Entry(name: title, isDir: false, data: ContainerSection(title: title)))
      entries += members.map {
        Entry(name: $0.name, isDir: false, data: ContainerTarget(name: $0.name, service: services[$0.name], status: $0.status, details: $0.details))
      }
    }
    return entries
  }

  /// A は、カーソルのコンテナの作成設定（保存済み、または Compose から取り込めるもの）を開ける。
  var canEditSettings: Bool {
    guard ssh == nil, ready, let target = current?.data as? ContainerTarget, target.service != nil else { return false }
    return nativeProject != nil || project != nil
  }

  override var functionKeyLayout: [(String, String)?]? {
    guard ssh == nil else { return nil }
    var keys = Array<(String, String)?>(repeating: nil, count: 12)
    if canPerformContainerAction("create") { keys[0] = ("Create", "C") }
    if canPerformContainerAction("start") { keys[1] = ("Up", "U") }
    if canPerformContainerAction("stop") { keys[2] = ("Stop", "S") }
    if canPerformContainerAction("delete") { keys[3] = ("Delete", "D") }
    if canEditSettings { keys[4] = ("Attr", "A") }
    if canShowLogs { keys[11] = ("Container", "") }
    return keys
  }

  override var commands: [Operation: Command] {
    if ssh != nil {
      var result = super.commands
      result[.transfer] = ContainerTransfer(upload: false)
      return result
    }
    return [.enter: ContainerEnter(), .reload: ReloadCommand(), .extract: ContainerAction("start"),
      .shell: ContainerAction("stop"), .create: ContainerAction("create"),
      .delete: ContainerAction("delete"), .format: ComposeFiles(), .chmod: ContainerSettingsCommand(), .logs: ContainerLogs()]
  }
  override var transferCommand: Command? { ContainerTransfer(upload: true) }

  override func allowsKey(_ id: String) -> Bool {
    if ssh == nil, id.hasPrefix("f"), let number = Int(id.dropFirst()) {
      guard (1...12).contains(number) else { return false }
      guard let keys = functionKeyLayout else { return false }
      return keys[number - 1] != nil
    }
    return super.allowsKey(id) || ["enter", "char:l", "char:u", "char:s", "char:c", "char:d", "char:f", "char:a", "char: ", "char:　", "char:*", "delete", "f2", "f4", "f9"].contains(id)
  }

  func refreshContext() async {
    let root = NativeContainerProject.findRoot(localDirectory()) ?? localDirectory()
    if ssh == nil && filesDirectory != root { await load() }
  }

  override func fetch() async throws -> [Entry] {
    notice = nil
    if ssh != nil { return try await super.fetch() }
    guard #available(macOS 26, *) else { notice = [tr("container.requires_macos")]; return [] }
    guard FileManager.default.isExecutableFile(atPath: client.executable) else { notice = [tr("container.not_installed")]; return [] }
    serviceStopped = !(try await client.systemRunning())
    if serviceStopped {
      notice = [tr("container.system_stopped")]
      return []
    }
    let directory = NativeContainerProject.findRoot(localDirectory()) ?? localDirectory()
    if filesDirectory != directory { selectedFiles = nil; filesDirectory = directory }
    let files = selectedFiles ?? ComposeProject.discover(directory)
    project = nil
    nativeProject = nil
    var composeError: String?
    if FileManager.default.fileExists(atPath: NativeContainerProject.settings(directory)) {
      do { nativeProject = try NativeContainerProject.read(directory) }
      catch { composeError = errorMessage(error) }
    } else if !files.isEmpty {
      do { project = try ComposeProject.load(files, listingOnly: true) }
      catch { composeError = errorMessage(error) }
    }
    let containers = try await client.list()
    if byNetwork { return try await networkEntries(containers) }
    // 設定のあるもの（保存済みの設定か compose）を、稼働中（current (up)）とそれ以外（current (down)）に分ける。
    // 設定のないコンテナは、稼働中のものだけ other に出す。最後に今のフォルダーの Dockerfile。
    var current: [Entry] = []
    var seen = Set<String>()
    // 未作成のものは、保存した作成設定から帯に出す設定を読む。
    var definitions: [(service: String, name: String, details: ContainerDetails)] = []
    if let nativeProject {
      definitions = nativeProject.definitions.map { (service: $0.service, name: $0.name, details: ContainerDetails(image: $0.image, create: $0.create)) }
    } else if let project {
      definitions = project.services.keys.sorted().map { (service: $0, name: project.containerName($0), details: ContainerDetails()) }
    }
    for (service, name, details) in definitions {
      seen.insert(name)
      let found = containers.first { $0.name == name }
      current.append(Entry(name: service, isDir: false,
        data: ContainerTarget(name: name, service: service, status: found?.status ?? "missing", details: found?.details ?? details)))
    }
    let other = containers.filter { !seen.contains($0.name) && $0.running }.sorted { $0.name < $1.name }.map {
      Entry(name: $0.name, isDir: false, data: ContainerTarget(name: $0.name, service: nil, status: $0.status, details: $0.details))
    }
    var dockerfileEntries: [Entry] = []
    // 今のフォルダーの Dockerfile。保存済みの設定がビルドに使っているものは重ねて出さない。
    let used = Set((nativeProject?.definitions ?? []).flatMap { definition in
      definition.prepare.filter { $0.first == "build" }.compactMap { step in step.firstIndex(of: "--file").flatMap { $0 + 1 < step.count ? step[$0 + 1] : nil } }
    }.map { p.normalize($0) })
    let here = localDirectory()
    let dockerfiles = ((try? FileManager.default.contentsOfDirectory(atPath: here)) ?? []).filter(DockerfileTarget.isDockerfile).sorted()
      .map { p.join(here, $0) }.filter { !used.contains(p.normalize($0)) }
    if !dockerfiles.isEmpty {
      let images = (try? await client.imageNames()) ?? []
      dockerfileEntries = dockerfiles.map { path in
        let image = DockerfileTarget.imageName(path)
        return Entry(name: p.basename(path), isDir: false,
          data: DockerfileTarget(path: path, image: image, built: images.contains(ContainerClient.normalizedImage(image))))
      }
    }
    func running(_ entry: Entry) -> Bool { (entry.data as? ContainerTarget)?.running == true }
    var entries: [Entry] = []
    for (key, block) in [("current_up", current.filter(running)), ("current_down", current.filter { !running($0) }),
      ("other", other), ("dockerfile", dockerfileEntries)] where !block.isEmpty {
      let title = tr("container.section.\(key)")
      entries.append(Entry(name: title, isDir: false, data: ContainerSection(title: title)))
      entries += block
    }
    // 壊れた compose があっても、既存のコンテナには接続できる。
    if let composeError { app.showStatus(composeError) }
    return entries
  }

  override func open(_ entry: Entry) async {
    if let dockerfile = entry.data as? DockerfileTarget { await createFromDockerfile(dockerfile); return }
    guard let target = entry.data as? ContainerTarget else { await super.open(entry); return }
    do {
      if !target.running {
        if target.status == "missing" {
          // 未作成のサービスは、Dockerfile と同じく名前と設定を確かめてから作る（起動はしない）。
          guard let definition = try currentConfiguration().definitions.first(where: { $0.name == target.name }) else {
            app.showStatus(tr("container.no_settings")); return
          }
          await createWithSettings(definition, isNew: false, prompt: tr("container.name_prompt"))
          return
        } else {
          guard await app.confirm(tr("container.start"), tr("container.start_confirm", ["name": target.name])) else { return }
          guard try await checkPortsBeforeStart(target.name) else { return }
          _ = try await app.withProgress(tr("container.starting")) { try await client.checked(["start", target.name]) }
        }
      }
      // 作ったばかりのコンテナもあるので、マウントは今の一覧から読む。
      let binds = target.running ? target.details.binds : (try await client.list().first { $0.name == target.name }?.details.binds ?? [])
      let connection = ContainerConnection(target.name, client: client, binds: binds)
      // sh のないイメージは、ここで理由を出して一覧に戻す。
      let home: String
      do { home = try await connection.home() }
      catch { throw AppError(tr("container.no_shell", ["name": target.name, "error": errorMessage(error)])) }
      await disconnect(reload: false)
      ssh = connection
      try await goTo(home)
    } catch { await app.showError(error); await load() }
  }

  /// Enter は、サービス停止中の案内からも起動確認を開ける。
  func enter() async {
    if serviceStopped {
      guard await app.confirm(tr("container.start_system"), tr("container.start_system_confirm")) else { return }
      do { _ = try await app.withProgress(tr("container.starting")) { try await client.checked(["system", "start"]) } }
      catch { await app.showError(error) }
      await load()
    } else if let current { await open(current) }
  }

  /// 一覧にある名前だけを使い、操作は Apple Container に直接依頼する。
  func containerAction(_ action: String, targets: [Mark]) async {
    guard !loading else { return }
    var errors: [String] = []
    do {
      let existing = try await client.list()
      let selected = targets.compactMap { mark -> (Mark, ContainerTarget)? in
        guard let target = mark.entry.data as? ContainerTarget else { return nil }
        return (mark, target)
      }
      let jobs = selected.filter { _, target in
        let found = existing.first { $0.name == target.name }
        switch action {
        case "create": return found == nil
        case "start": return found?.status.lowercased() == "stopped"
        case "stop": return found?.running == true
        case "delete": return found?.status.lowercased() == "stopped"
        default: return false
        }
      }
      if action == "create" {
        if selected.isEmpty { _ = try await createContainer(name: nil) }
        else {
          if jobs.isEmpty { app.showStatus(tr("container.no_action_targets")); return }
          for (mark, target) in jobs {
            do {
              let result = try await createContainer(name: target.name)
              if result == .cancelled { break }
              // 失敗の出力は端末に残したので、ここでは重ねて知らせない。
              if result == .created { marks.removeValue(forKey: keyOf(mark.entry)) }
            } catch { errors.append("\(target.name): \(errorMessage(error))") }
          }
        }
      } else {
        guard !jobs.isEmpty else { app.showStatus(tr("container.no_action_targets")); return }
        let messageKey = action == "delete" ? "container.bulk_delete_confirm" : action == "stop" ? "container.bulk_stop_confirm" : "container.bulk_start_confirm"
        let message = tr(messageKey) + "\n\n" + jobs.map { $0.1.name }.joined(separator: "\n")
        guard await app.confirm(tr("container.\(action)"), message, yes: tr("container.\(action)")) else { return }
        await app.withProgress(tr("container.progress_action")) {
          for (mark, target) in jobs {
            do {
              if action == "start" {
                let ports = existing.first { $0.name == target.name }?.details.ports ?? []
                let conflicts = try await portConflicts(publishing: ports, container: target.name)
                if !conflicts.isEmpty { errors.append(portConflictMessage(target.name, conflicts)); continue }
              }
              try await client.checked([action, target.name])
              marks.removeValue(forKey: keyOf(mark.entry))
            } catch { errors.append("\(target.name): \(errorMessage(error))") }
          }
        }
      }
    } catch { errors.append(errorMessage(error)) }
    await load()
    if !errors.isEmpty { await app.showError(errors.joined(separator: "\n")) }
  }

  /// カーソルのコンテナの作成設定を変えて保存する。作成済みなら、確認して新しい設定で作り直す（動いていたら起動し直す）。
  func editSettings() async {
    guard canEditSettings, let target = current?.data as? ContainerTarget else { return }
    do {
      let configuration: NativeContainerProject
      if let nativeProject { configuration = nativeProject }
      else if let project { configuration = try NativeContainerProject.importDraft(project) }
      else { return }
      guard let found = configuration.definitions.first(where: { $0.name == target.name }) else {
        app.showStatus(tr("container.no_settings")); return
      }
      let definition = reimported(found, root: configuration.root)
      if let problem = definition.problem { throw AppError(problem) }
      // 空にしたメモリ・CPU は、作り直すときに既定値を書く。ポートがほかで使われていれば、設定窓に戻して直してもらう。
      guard let updated = try await askSettings(target.name, definition),
        updated.create != definition.create || updated.prepare != definition.prepare else { return }
      nativeProject = try configuration.replacing(updated)
      guard let existing = try await client.list().first(where: { $0.name == target.name }) else {
        app.showStatus(tr("container.settings_saved")); await load(); return
      }
      guard await app.confirm(tr("container.recreate"), tr("container.recreate_confirm", ["name": target.name]), yes: tr("container.recreate")) else {
        app.showStatus(tr("container.settings_saved")); await load(); return
      }
      let steps = (existing.running ? [["stop", target.name]] : []) + [["delete", target.name]]
        + (try await nativeProject!.createSteps(updated, client: client)) + (existing.running ? [["start", target.name]] : [])
      _ = await runSteps(target.name, steps, in: nativeProject!.root, verb: "delete && container create")
    } catch { await app.showError(error) }
    await load()
  }

  /// 作れない理由付きで保存した設定は、Compose から取り込み直す（fm-ee2e の版が上がって、変換できるようになったときのため）。
  /// 取り込み直しても作れなければ、そのまま返す。
  private func reimported(_ definition: NativeContainerDefinition, root: String) -> NativeContainerDefinition {
    guard definition.problem != nil else { return definition }
    let files = selectedFiles ?? ComposeProject.discover(root)
    guard !files.isEmpty, let compose = try? ComposeProject.load(files),
      let fresh = (try? NativeContainerProject.importDraft(compose))?.definitions.first(where: { $0.service == definition.service }),
      fresh.problem == nil else { return definition }
    return fresh.renamed(definition.name)
  }

  /// 保存した設定か Compose を元にした設定。どちらもなければ、今のフォルダーに新しく作る。
  private func currentConfiguration() throws -> NativeContainerProject {
    if let nativeProject { return nativeProject }
    if let project { return try NativeContainerProject.importDraft(project) }
    return NativeContainerProject(root: NativeContainerProject.findRoot(localDirectory()) ?? localDirectory(), definitions: [])
  }

  /// Dockerfile から作るコンテナの設定の下書き。名前はあとで聞く。
  func createFromDockerfile(_ dockerfile: DockerfileTarget) async {
    let suggested = String(dockerfile.image.prefix { $0 != ":" })
    var draft = NativeContainerDefinition(service: suggested, name: suggested, image: dockerfile.image,
      create: ["create", "--name", suggested, "--dns-domain", "container", dockerfile.image],
      prepare: [["build", "--tag", dockerfile.image, "--file", dockerfile.path, p.dirname(dockerfile.path)]], problem: nil)
    // EXPOSE のポートは、同じ番号で公開する設定にしておく。
    var settings = ContainerSettings(draft)
    settings.ports = DockerfileTarget.exposedPorts((try? String(contentsOfFile: dockerfile.path, encoding: .utf8)) ?? "")
    if !settings.ports.isEmpty, let withPorts = try? settings.applied(to: draft) { draft = withPorts }
    await createWithSettings(draft, isNew: true, prompt: tr("container.dockerfile_name_prompt", ["file": p.basename(dockerfile.path)]))
  }

  /// 設定窓を開き、決めた設定を返す。Mac 側のポートがほかで使われていれば、知らせてから設定窓に戻す。
  private func askSettings(_ name: String, _ definition: NativeContainerDefinition) async throws -> NativeContainerDefinition? {
    var settings = ContainerSettings(definition)
    while true {
      let current = settings
      guard let edited: ContainerSettings = await app.showModal({ close in ContainerSettingsDialog(name, current, close) }) else { return nil }
      let updated = try edited.applied(to: definition).withDefaults()
      let conflicts = try await portConflicts(updated.create, container: name)
      if conflicts.isEmpty { return updated }
      await app.showError(tr("container.port_conflict", ["ports": conflicts.joined(separator: "\n")]) + "\n" + tr("container.port_change_hint"))
      settings = edited
    }
  }

  /// 名前を聞き、設定窓で設定を確かめてから保存し、端末の枠でビルド・作成する（起動はしない）。
  /// [isNew] なら設定に足し、そうでなければ同じサービスの設定と置き換える。Dockerfile と未作成のサービスの Enter で使う。
  private func createWithSettings(_ saved: NativeContainerDefinition, isNew: Bool, prompt: String) async {
    do {
      let configuration = try currentConfiguration()
      let draft = reimported(saved, root: configuration.root)
      if let problem = draft.problem { throw AppError(problem) }
      // 名前が使えない・ほかとぶつかるときは、知らせてから入れた名前のまま入力に戻す（ポートと同じ）。
      var initial = draft.name
      var name = ""
      while true {
        guard let entered = await app.input(tr("container.create"), message: prompt, initial: initial), !entered.isEmpty else { return }
        name = entered.trimmingCharacters(in: .whitespaces)
        initial = name
        guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else {
          await app.showError(tr("container.invalid_name", ["name": name])); continue
        }
        // 置き換える設定そのものは除いて、ほかの設定・コンテナと名前がぶつからないか確かめる。
        let service = isNew ? name : draft.service
        let taken = configuration.definitions.contains { other in
          (isNew || other.service != draft.service) && (other.name == name || other.service == service)
        }
        let used = try await client.list().contains { $0.name == name }
        if taken || used {
          await app.showError(tr("container.name_in_use", ["name": name])); continue
        }
        break
      }
      let service = isNew ? name : draft.service
      let prepared = try draft.renamed(name, service: service).withDefaults()
      guard let definition = try await askSettings(name, prepared) else { return }
      let saved = try isNew ? configuration.adding(definition) : configuration.replacing(definition)
      nativeProject = saved
      _ = await runSteps(name, try await saved.createSteps(definition, client: client), in: saved.root)
    } catch { await app.showError(error) }
    await load()
  }

  /// [container] が使う Mac 側の公開ポートのうち、ほかで使われているもの（どのポートを何が使っているか）。
  /// ほかのコンテナの公開ポートを先に見て、なければ Mac のプロセスを lsof で見る。[container] 自身が今使っているポートは除く。
  func portConflicts(_ create: [String], container: String) async throws -> [String] {
    try await portConflicts(publishing: zip(create, create.dropFirst()).filter { $0.0 == "--publish" || $0.0 == "-p" }.map(\.1), container: container)
  }

  /// [publishing]（--publish の値）のうち、Mac 側のポートがほかで使われているもの。
  func portConflicts(publishing values: [String], container: String) async throws -> [String] {
    let publishes = values.compactMap(ContainerClient.publishedHostPort)
    guard !publishes.isEmpty else { return [] }
    let containers = try await client.list()
    func held(_ info: ContainerInfo) -> [(port: Int, proto: String)] { info.running ? info.details.ports.compactMap(ContainerClient.publishedHostPort) : [] }
    let own = containers.first { $0.name == container }.map(held) ?? []
    var conflicts: [String] = []
    for (port, proto) in publishes {
      let label = proto == "tcp" ? "\(port)" : "\(port)/\(proto)"
      if let other = containers.first(where: { $0.name != container && held($0).contains { $0 == (port, proto) } }) {
        conflicts.append(tr("container.port_in_use_container", ["port": label, "name": other.name]))
      } else if !own.contains(where: { $0 == (port, proto) }), let process = await client.hostListeners(port, proto: proto).first {
        conflicts.append(tr("container.port_in_use_process", ["port": label, "name": process.name, "pid": process.pid]))
      }
    }
    return conflicts
  }

  /// 作成済みのコンテナを起動する前に確かめる。ぶつかっていれば知らせて false（A でポートを直すよう案内する）。
  private func checkPortsBeforeStart(_ name: String) async throws -> Bool {
    let ports = try await client.list().first { $0.name == name }?.details.ports ?? []
    let conflicts = try await portConflicts(publishing: ports, container: name)
    if conflicts.isEmpty { return true }
    await app.showError(portConflictMessage(name, conflicts))
    return false
  }

  private func portConflictMessage(_ name: String, _ conflicts: [String]) -> String {
    "\(name): " + tr("container.port_conflict", ["ports": conflicts.joined(separator: "\n")]) + "\n" + tr("container.port_fix_hint")
  }

  enum CreateResult { case created, cancelled, failed }

  /// container コマンドを枠の中の端末で順に動かし、進み具合を見せる。失敗したときだけ出力を残して Enter を待つ。
  private func runSteps(_ name: String, _ steps: [[String]], in directory: String, verb: String = "create") async -> Bool {
    let code = await runInTerminal(app, "\(name) $ container \(verb)", "/bin/sh", ["-c", Self.stepScript(client.executable, steps)],
      workingDirectory: directory, waitAfterExit: { $0 != 0 })
    return code == 0
  }

  /// 各コマンドを表示してから実行し、失敗したところで止める sh のスクリプト。引数はすべて引用する。
  static func stepScript(_ executable: String, _ steps: [[String]]) -> String {
    (["set -e"] + steps.flatMap { step in
      ["printf '%s\\n' \(shQuote("$ container " + step.joined(separator: " ")))", ([executable] + step).map(shQuote).joined(separator: " ")]
    }).joined(separator: "\n")
  }

  /// 保存済み設定を優先し、初回は Compose から独立した設定を作る。
  private func createContainer(name suggested: String?) async throws -> CreateResult {
    let name: String
    if let suggested { name = suggested }
    else {
      guard let entered = await app.input(tr("container.create"), message: tr("container.name_prompt")), !entered.isEmpty else { return .cancelled }
      name = entered
    }
    let configuration: NativeContainerProject?
    if let nativeProject { configuration = nativeProject }
    else if let project { configuration = try NativeContainerProject.importDraft(project) }
    else { configuration = nil }
    if var configuration, let found = configuration.definitions.first(where: { $0.name == name }) {
      let saved = reimported(found, root: configuration.root)
      if let problem = saved.problem { throw AppError(problem) }
      let definition = try saved.withDefaults()
      let message = tr("container.native_create_confirm", ["name": name, "image": definition.image])
        + "\n\n" + tr("container.saved_configuration") + "\n"
        + p.join(configuration.root, ".fm-ee2e", "containers", "\(definition.service).json5")
        + (definition.notes.isEmpty ? "" : "\n\n" + definition.notes.joined(separator: "\n"))
      guard await app.confirm(tr("container.create"), message, yes: tr("container.create")) else { return .cancelled }
      let conflicts = try await portConflicts(definition.create, container: name)
      if !conflicts.isEmpty { await app.showError(portConflictMessage(name, conflicts)); return .failed }
      // 既定値を足したり取り込み直したりしたら、その設定を保存してから作る。
      if definition.create != found.create { configuration = try configuration.replacing(definition) }
      else if nativeProject == nil { try configuration.save() }
      nativeProject = configuration
      let steps = try await configuration.createSteps(definition, client: client)
      if await runSteps(name, steps, in: configuration.root) { return .created }
      // 非公開の ECR は、プロファイルを指定したときだけ認証を更新して一度やり直す。
      guard let profile = configuration.awsProfile, !profile.isEmpty, let registry = ContainerClient.ecrRegistry(in: definition.image) else { return .failed }
      try await app.withProgress(tr("container.progress_action")) { try await client.authenticateEcr(registry.host, region: registry.region, profile: profile) }
      let retry = try await configuration.createSteps(definition, client: client)
      return await runSteps(name, retry, in: configuration.root) ? .created : .failed
    }
    guard let image = await app.input(tr("container.create"), message: tr("container.image_prompt")), !image.isEmpty else { return .cancelled }
    guard let options = await app.input(tr("container.create"), message: tr("container.options_prompt")) else { return .cancelled }
    guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else {
      throw AppError(tr("container.invalid_saved_config", ["file": name]))
    }
    let args = ["create", "--name", name, "--dns-domain", "container"] + (try splitComposeCommand(options)) + [image]
    let message = tr("container.native_create_confirm", ["name": name, "image": image])
      + (options.isEmpty ? "" : "\n\n" + tr("container.native_options") + "\n" + options)
    guard await app.confirm(tr("container.create"), message, yes: tr("container.create")) else { return .cancelled }
    let definition = try NativeContainerDefinition(service: name, name: name, image: image, create: args, prepare: [], problem: nil).withDefaults()
    let conflicts = try await portConflicts(definition.create, container: name)
    if !conflicts.isEmpty { await app.showError(portConflictMessage(name, conflicts)); return .failed }
    let saved = NativeContainerProject(root: nativeProject?.root ?? NativeContainerProject.findRoot(localDirectory()) ?? localDirectory(),
      definitions: (nativeProject?.definitions ?? []) + [definition], awsProfile: nativeProject?.awsProfile)
    try saved.save()
    nativeProject = saved
    return await runSteps(name, [definition.create], in: saved.root) ? .created : .failed
  }

  /// プロジェクトのフォルダーにある Compose の YAML（名前に compose を含むもの）。
  static func composeCandidates(_ directory: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter {
      $0.lowercased().contains("compose") && ($0.hasSuffix(".yml") || $0.hasSuffix(".yaml"))
    }.sorted()
  }

  /// 重ねる Compose ファイルを、一覧から重ねる順に1つずつ選ぶ（F）。何も選ばずに決めると自動の選び方に戻る。
  func chooseComposeFiles() async {
    let directory = NativeContainerProject.findRoot(localDirectory()) ?? localDirectory()
    let found = Self.composeCandidates(directory)
    guard !found.isEmpty else { app.showStatus(tr("container.no_compose_files")); return }
    var chosen: [String] = []
    while chosen.count < found.count {
      let remaining = found.filter { !chosen.contains($0) }
      let note = chosen.isEmpty ? tr("container.files_first") : tr("container.files_order", ["files": chosen.joined(separator: " → ")])
      guard let index = await app.askChoice(tr("container.files_title"), [tr("container.files_done"), ""] + remaining, note: note) else { return }
      if index == 0 { break }
      chosen.append(remaining[index - 2])
    }
    let files = chosen.map { p.join(directory, $0) }
    do {
      if !files.isEmpty { _ = try ComposeProject.load(files, listingOnly: true) }
      filesDirectory = directory
      selectedFiles = files.isEmpty ? nil : files
      await load()
    } catch { await app.showError(error) }
  }

  override func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ width: Int, _ rows: Int, focused: Bool) {
    widestDetail = entries.map { textWidth(detailOf($0)) }.max() ?? 0
    super.drawBody(screen, x, y, width, rows, focused: focused)
  }

  /// 右端の列に出すもの。サービスならコンテナ名、Dockerfile ならイメージ名。設定のないコンテナは名前の列と同じなので出さない。
  private func detailOf(_ entry: Entry) -> String {
    if let dockerfile = entry.data as? DockerfileTarget { return dockerfile.image }
    if let target = entry.data as? ContainerTarget, target.service != nil, target.name != entry.name { return target.name }
    return ""
  }

  /// 名前を左に、状態とコンテナ名（Dockerfile はイメージ名）を右端に寄せて描く（ほかのタブのサイズ・日時と同じ並び）。
  /// 狭い窓ではコンテナ名の列を省く。
  override func drawRow(_ screen: Screen, _ entry: Entry, _ x: Int, _ y: Int, _ width: Int, _ style: Style, marked: Bool) {
    if let section = entry.data as? ContainerSection {
      let line = "── \(section.title) " + String(repeating: "─", count: max(0, width - textWidth(section.title) - 5))
      screen.text(x + 1, y, truncate(line, max(0, width - 1)), style.copyWith(fg: colors.muted, bold: true), maxWidth: max(0, width - 1))
      return
    }
    if let dockerfile = entry.data as? DockerfileTarget {
      drawColumns(screen, entry.name, dockerfile.built ? "built" : Self.noneLabel, detailOf(entry), x, y, width, style, highlight: false, marked: marked)
      return
    }
    guard let target = entry.data as? ContainerTarget else { super.drawRow(screen, entry, x, y, width, style, marked: marked); return }
    drawColumns(screen, entry.name, target.status == "missing" ? Self.noneLabel : target.status, detailOf(entry), x, y, width, style,
      highlight: target.running, marked: marked)
  }

  /// まだ作っていないコンテナ・ビルドしていないイメージの状態の表示（ほかのタブの <DIR>・<UP> と同じ書き方）。
  static let noneLabel = "<NONE>"

  private func drawColumns(_ screen: Screen, _ name: String, _ status: String, _ detail: String,
    _ x: Int, _ y: Int, _ width: Int, _ style: Style, highlight: Bool, marked: Bool) {
    let contentWidth = max(0, width - 3)
    guard contentWidth > 0 else { return }
    let statusWidth = min(9, max(0, contentWidth - 5))
    let detailWidth = width >= 50 && widestDetail > 0 ? min(widestDetail, contentWidth / 2) : 0
    let right = statusWidth + (detailWidth > 0 ? 1 + detailWidth : 0)
    let nameWidth = max(0, contentWidth - right - (right > 0 ? 1 : 0))
    let rowStyle = style.copyWith(fg: marked ? Palette.marked : highlight ? accent : colors.muted, bold: marked)
    screen.text(x, y, marked ? "*" : " ", style.copyWith(fg: Palette.marked, bold: true))
    screen.text(x + 2, y, truncate(name, nameWidth), rowStyle, maxWidth: nameWidth)
    let end = x + 2 + contentWidth
    if detailWidth > 0, !detail.isEmpty {
      screen.text(end - detailWidth, y, truncate(detail, detailWidth), rowStyle, maxWidth: detailWidth)
    }
    if statusWidth > 0 {
      let status = truncate(status, statusWidth)
      let statusEnd = end - (detailWidth > 0 ? detailWidth + 1 : 0)
      screen.text(statusEnd - textWidth(status), y, status, rowStyle, maxWidth: statusWidth)
    }
  }
}
