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

/// 今のフォルダーにある Dockerfile・Containerfile。Enter で、そこから作るコンテナの設定を作り、ビルドして作成する。
struct DockerfileTarget {
  let path: String
  /// ビルドしてつけるイメージの名前（フォルダー名から決める）。
  let image: String
  let built: Bool

  /// Containerfile（Containerfile.<名前>、<名前>.Containerfile を含む）。一覧では Dockerfile と別のブロックに出す。
  var isContainerfile: Bool { Self.stem(p.basename(path)) == "containerfile" }

  /// ファイル名の土台（dockerfile か containerfile）。どちらでもなければ nil。
  private static func stem(_ name: String) -> String? {
    let lower = name.lowercased()
    return ["dockerfile", "containerfile"].first { lower == $0 || lower.hasPrefix("\($0).") || lower.hasSuffix(".\($0)") }
  }

  /// Dockerfile、Dockerfile.<名前>、<名前>.Dockerfile と、同じ形の Containerfile。
  static func isDockerfile(_ name: String) -> Bool { stem(name) != nil }

  /// フォルダー名を土台に、Dockerfile.dev なら -dev、api.Dockerfile なら -api を付けた名前（タグは latest）。Containerfile も同じ。
  static func imageName(_ path: String) -> String {
    func clean(_ text: String) -> String {
      let mapped = text.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "-" }
      return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
    }
    let base = clean(p.basename(p.dirname(path)))
    let file = p.basename(path)
    let lower = file.lowercased()
    let length = (stem(file) ?? "dockerfile").count + 1
    let suffix = lower == stem(file) ? "" : lower.hasPrefix("\(stem(file) ?? "").") ? String(file.dropFirst(length)) : String(file.dropLast(length))
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
        // 30000 台のポートは、Mac 側（外向け）をその番号、コンテナ側（内向け）を 30000 を引いた番号にする（EXPOSE 30443 → 30443:443）。
        let inside = (30001...39999).contains(port) ? port - 30000 : port
        let value = "\(port):\(inside)" + (parts.count > 1 && parts[1].lowercased() != "tcp" ? "/" + parts[1].lowercased() : "")
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
  /// [localDirectory] のファイルを書き換えたあとに、そのローカルのタブを読み直す。
  var reloadLocal: () async -> Void = {}
  private(set) var project: ComposeProject?
  private var nativeProject: NativeContainerProject?
  private var selectedFiles: [String]?
  private var filesDirectory: String?
  private var notice: [String]?
  private var serviceStopped = false
  /// サービスが動いているかを確かめられたか（macOS が古い・container がないときは確かめない）。
  private var serviceChecked = false
  /// F12 の Command で打ったコマンド（コンテナ名ごと、古い順）。どこにも書き込まない。
  private var runHistory: [String: [String]] = [:]
  /// 一覧をネットワークごとに並べる（by Network）。これが最初の並び。F12 の先頭の by Status で状態ごとの並びに替え、by Network で戻す。
  private(set) var byNetwork = true
  private var widestDetail = 0
  /// 一覧を読んだときにあったイメージ（Apple Container の一覧と同じ形の名前）。D でイメージだけの行を消すのに使う。
  private var presentImages = Set<String>()
  /// --dns-domain を付けない設定のコンテナが使う DNS ドメイン。まだ作っていないコンテナの「名前.ドメイン」を組み立てるのに使う。
  private var defaultDNSDomain: String?

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
  override func selectable(_ entry: Entry) -> Bool { !(entry.data is ContainerSection) && super.selectable(entry) }
  override var folderKey: String { ssh == nil ? "container-list" : super.folderKey }
  override func keyOf(_ entry: Entry) -> String {
    if let target = entry.data as? ContainerTarget { return "container:\(target.name)" }
    return super.keyOf(entry)
  }
  override var keyOperations: [String: Operation] {
    ssh == nil ? ["char:c": .create, "f1": .create, "f2": .extract, "f3": .shell, "f4": .delete, "f5": .chmod, "f12": .logs, "ctrl:c": .compose] : [:]
  }

  var targetStatuses: Set<String> {
    Set(targetMarks.compactMap { ($0.entry.data as? ContainerTarget)?.status.lowercased() })
  }

  /// コンテナがなくイメージだけがある行（未作成のコンテナ・ビルド済みの Dockerfile）の、そのイメージ。D で消す。
  func imageOnly(_ entry: Entry) -> String? {
    let image: String?
    switch entry.data {
    case let target as ContainerTarget: image = target.status == "missing" ? target.details.image : nil
    case let dockerfile as DockerfileTarget: image = dockerfile.image
    default: image = nil
    }
    return image.map(ContainerClient.normalizedImage).flatMap { presentImages.contains($0) ? $0 : nil }
  }

  func canPerformContainerAction(_ action: String) -> Bool {
    guard ssh == nil && ready else { return false }
    // D は、停止中のコンテナとイメージだけの行を一緒に消せる。
    if action == "delete" {
      let targets = targetMarks
      return !targets.isEmpty && targets.allSatisfy {
        ($0.entry.data as? ContainerTarget)?.status.lowercased() == "stopped" || imageOnly($0.entry) != nil
      }
    }
    guard targetStatuses.count == 1 else { return false }
    switch action {
    case "create": return targetStatuses.contains("missing")
    case "start": return targetStatuses.contains("stopped")
    case "stop": return targetStatuses.contains("running")
    default: return false
    }
  }

  /// L（読み直し）。コンテナの一覧を出しているときは、今のフォルダーの docker-compose（Ctrl+C で選んだファイルがあればそれ）から
  /// 保存済みの設定（.fm-ee2e/project.json5・containers/*.json5）を作り直してから読み直す。
  override func reload() async {
    if ssh == nil && ready && !serviceStopped { rebuildFromCompose() }
    await super.reload()
  }

  private func rebuildFromCompose() {
    let directory = NativeContainerProject.findRoot(localDirectory()) ?? localDirectory()
    let files = (filesDirectory == directory ? selectedFiles : nil) ?? ComposeProject.discover(directory)
    guard !files.isEmpty else { return }
    do {
      nativeProject = try NativeContainerProject.rebuild(try ComposeProject.load(files), root: directory)
      app.showStatus(tr("container.rebuilt_from_compose"))
    } catch {
      app.showStatus(errorMessage(error))
    }
  }

  /// F12 は、コンテナの一覧を出しているときに使える。
  var canShowMenu: Bool { ssh == nil && ready }

  /// F12 のメニュー。表示の切り替え・Containerfile・イメージの取得と削除を選び、空行を挟んで一番下にログを並べる。
  /// ログは画面全体の端末で見せる（終わったあとも ↑↓ PgUp PgDn でさかのぼれる）。コンテナ自身のログは、カーソルが作成済みのコンテナの上にあるときだけ選べる。
  func showMenu() async {
    guard canShowMenu else { return }
    let target = current?.data as? ContainerTarget
    let prefix = target.map { "\($0.name) $ " } ?? ""
    func logs(_ args: [String]) -> () async -> Void {
      { [self] in await runInTerminal(app, "\(prefix)container \(args.joined(separator: " "))", client.executable, args, frame: .page) }
    }
    var choices: [(String, () async -> Void)] = [
      (tr(byNetwork ? "container.logs.by_status" : "container.logs.by_network"), { [self] in
        byNetwork.toggle()
        resetCursor()
        await load()
      }),
      (tr("container.networks.menu"), { [self] in await manageNetworks() }),
    ]
    // 動いているコンテナではその中で（設定は要らない）、止まっているコンテナでは保存済みの設定があればコマンドを実行できる。
    // 今のフォルダーのプロジェクトにないコンテナ（共通のものなど）も、名前で設定を引く。
    if let target {
      let definition = (nativeProject?.definitions.first(where: { $0.name == target.name }) ?? NativeContainerProject.savedDefinition(target.name))
        .flatMap { $0.problem == nil ? $0 : nil }
      if target.running || definition != nil {
        choices.append((tr("container.command.menu"), { [self] in await runCommand(target, definition) }))
      }
    }
    choices += [
      // 今のフォルダーに Containerfile があれば直す、なければ作る項目として出す。
      (tr(FileManager.default.fileExists(atPath: p.join(localDirectory(), "Containerfile")) ? "container.containerfile.menu_modify" : "container.containerfile.menu_create"),
        { [self] in await createContainerfile() }),
      (tr("container.images.pull"), { [self] in await pullImage() }),
      (tr("container.images.delete"), { [self] in await deleteImages() }),
      // 空の行は選べない区切り。
      ("", {}),
    ]
    if let target, target.status != "missing" {
      choices.append((tr("container.logs.output"), logs(["logs", target.name])))
      choices.append((tr("container.logs.boot"), logs(["logs", "--boot", target.name])))
    }
    choices.append((tr("container.logs.system"), logs(["system", "logs"])))
    // 一番下に、1行空けてサービスの停止。
    choices += [("", {}), (tr("container.shutdown"), { [self] in await shutdown() })]
    let title = target.map { tr("container.menu.title_for", ["name": $0.name]) } ?? tr("container.menu.title")
    guard let index = await app.askChoice(title, choices.map(\.0)) else { return }
    await choices[index].1()
  }

  /// 小窓の条件で Docker Hub を探し、イメージとタグを一覧から選んで、container image pull で取得する。
  /// 一覧で Esc を押したとき、見つからなかったときは、入れた条件のまま小窓に戻る。
  /// 取得の進み具合は端末の枠に出し、失敗したときは出力を残して Enter を待つ。
  private func pullImage() async {
    var query = ImageSearchDialog.Query()
    while true {
      let current = query
      guard let entered: ImageSearchDialog.Query = await app.showModal({ close in ImageSearchDialog(current, close) }) else { return }
      query = entered
      if query.image.isEmpty {
        app.showStatus(tr("container.images.search_required"))
        continue
      }
      do {
        let repositories = try await app.withProgress(tr("container.images.searching")) { try await DockerHub.search(query.image) }
        if repositories.isEmpty {
          app.showStatus(tr("container.images.no_results", ["query": query.image]))
          continue
        }
        let labels = repositories.map { repository in
          [repository.repoName, "★\(repository.starCount ?? 0)", repository.isOfficial == true ? tr("container.images.official") : nil,
            repository.shortDescription.flatMap { $0.isEmpty ? nil : $0 }].compactMap { $0 }.joined(separator: "  ")
        }
        guard let chosen = await app.askChoice(tr("container.images.choose_image"), labels) else { continue }
        let repository = repositories[chosen].repoName
        let tags = try await app.withProgress(tr("container.images.loading_tags")) {
          try await DockerHub.tags(repository, name: query.tag, architecture: query.architecture)
        }
        if tags.isEmpty {
          app.showStatus(tr("container.images.no_tags", ["image": repository, "arch": query.architecture]))
          continue
        }
        let tagLabels = tags.map { tag in [tag.name, tag.lastUpdated.map { String($0.prefix(10)) }].compactMap { $0 }.joined(separator: "  ") }
        guard let tagIndex = await app.askChoice(tr("container.images.choose_tag", ["image": repository, "arch": query.architecture]), tagLabels) else { continue }
        let reference = "\(repository):\(tags[tagIndex].name)"
        let pulled = await runSteps(reference, [["image", "pull", "--platform", "linux/\(query.architecture)", reference]], in: localDirectory(), verb: "image pull")
        await load()
        if pulled { app.showStatus(tr("container.images.pulled", ["image": reference])) }
        return
      } catch {
        await app.showError(error)
        return
      }
    }
  }

  /// F12 の Command。入力したコマンドを実行する（↑↓ でこのコンテナで打ったコマンド）。出力は残して Enter を待つ。
  /// 動いているコンテナでは、その中で実行する（container exec）。名前付きボリュームは動いている本体と同時に付けられないため。
  /// 動いていなければ、[definition] の設定で使い捨てのコンテナを作って実行し、消す。
  /// まだ作っていないコンテナでは、作成と同じくイメージ・ネットワーク・ボリュームを先に用意する。
  private func runCommand(_ target: ContainerTarget, _ definition: NativeContainerDefinition?) async {
    let project = nativeProject ?? NativeContainerProject(root: NativeContainerProject.findRoot(localDirectory()) ?? localDirectory(), definitions: [])
    guard let entered = await app.input(tr("container.command.menu"),
        message: tr(target.running ? "container.command.prompt_exec" : "container.command.prompt", ["name": target.name]),
        history: runHistory[target.name] ?? []),
      !entered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    var list = (runHistory[target.name] ?? []).filter { $0 != entered }
    list.append(entered)
    runHistory[target.name] = list
    do {
      let steps: [[String]]
      if target.running {
        steps = [["exec", "--interactive", "--tty", target.name, "/bin/sh", "-c", entered]]
      } else if let definition {
        guard let run = definition.runArgs(entered) else {
          throw AppError(tr("container.invalid_saved_config", ["file": definition.service]))
        }
        steps = (target.status == "missing" ? Array(try await project.createSteps(definition, client: client).dropLast()) : []) + [run]
      } else {
        return
      }
      await runInTerminal(app, "\(target.name) $ \(entered)", "/bin/sh", ["-c", Self.stepScript(client.executable, steps)],
        workingDirectory: project.root)
    } catch { await app.showError(error) }
    await load()
  }

  /// ネットワークの一覧。先頭の Create a new network で作り、既存のネットワークを選ぶと中身と使っているコンテナを見せる
  /// （コンテナがついていなければ、確認してから1つだけ消せる）。
  /// 作ったり見たりしたあとは一覧に戻り、Esc で終える。
  private func manageNetworks() async {
    while true {
      let networks: [(name: String, subnet: String)]
      let containers: [ContainerInfo]
      do {
        networks = try await client.networks().sorted { $0.name < $1.name }
        containers = try await client.list()
      } catch {
        await app.showError(error)
        return
      }
      let labels = networks.map { $0.subnet.isEmpty ? $0.name : "\($0.name)  \($0.subnet)" }
      guard let index = await app.askChoice(tr("container.networks.menu"), [tr("container.networks.create"), ""] + labels) else { return }
      if index == 0 {
        await createNetwork(networks)
        continue
      }
      let network = networks[index - 2]
      let parts = network.subnet.split(separator: "/").map(String.init)
      let values = NetworkDialog.Values(name: network.name, address: parts.first ?? "",
        netmask: parts.count > 1 ? Int(parts[1]).map(NetworkDialog.netmask) ?? parts[1] : "")
      let members = containers.filter { $0.details.networks.contains(network.name) }.map(\.name).sorted()
      // 小窓が値を返したら、そのネットワーク1つだけを消す（コンテナがついていないものだけ、小窓が Delete を出す）。
      guard let chosen: NetworkDialog.Values = await app.showModal({ close in NetworkDialog(showing: values, containers: members, close) }) else { continue }
      guard await app.confirm(tr("container.networks.delete_button"), tr("container.networks.delete_confirm", ["name": chosen.name])) else { continue }
      do {
        _ = try await app.withProgress(tr("container.progress_action")) { try await client.checked(["network", "delete", chosen.name]) }
        app.showStatus(tr("container.networks.deleted", ["name": chosen.name]))
        if byNetwork { await load() }
      } catch {
        await app.showError(error)
      }
    }
  }

  /// 名前・アドレス・ネットマスクを聞いて、ネットワークを作る。作れなければ、理由を下の行に出して入れた内容のまま小窓に戻す。
  /// 初期値は、今のフォルダー名の名前と、ほかのネットワークと重ならない 192.168.x.0/24。
  private func createNetwork(_ networks: [(name: String, subnet: String)]) async {
    let base = String(p.basename(localDirectory()).lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
    let stem = (base.isEmpty ? "network" : base) + "-net"
    let names = Set(networks.map(\.name))
    let name = names.contains(stem) ? (2...).lazy.map { "\(stem)\($0)" }.first { !names.contains($0) }! : stem
    let used = networks.compactMap { network -> Int? in
      let octets = network.subnet.split(separator: "/").first?.split(separator: ".") ?? []
      return octets.count == 4 && octets[0] == "192" && octets[1] == "168" ? Int(octets[2]) : nil
    }
    let third = (used.max().map { $0 + 1 } ?? 64)
    var values = NetworkDialog.Values(name: name, address: "192.168.\(min(third, 254)).0", netmask: "255.255.255.0")
    while true {
      let current = values
      guard let entered: NetworkDialog.Values = await app.showModal({ close in NetworkDialog(creating: current, close) }) else { return }
      values = entered
      guard let length = NetworkDialog.prefixLength(values.netmask) else {
        app.showStatus(tr("container.networks.invalid_netmask", ["netmask": values.netmask]))
        continue
      }
      do {
        _ = try await app.withProgress(tr("container.progress_action")) {
          try await client.checked(["network", "create", "--subnet", "\(values.address)/\(length)", values.name])
        }
        app.showStatus(tr("container.networks.created", ["name": values.name]))
        if byNetwork { await load() }
        return
      } catch {
        app.showStatus(errorMessage(error))
      }
    }
  }

  /// イメージを選んで削除する。消すたびに一覧を出し直し、Esc で終える。
  /// コンテナが使っているイメージには、そのコンテナ名を添える（消せるかは Apple Container に任せる）。
  private func deleteImages() async {
    while true {
      let images: [(name: String, platforms: [String])]
      let containers: [ContainerInfo]
      let layers: [String: [String: [String]]]
      do {
        images = try await client.imagePlatforms()
        containers = try await client.list()
        layers = try await client.imageLayers(images.map(\.name))
      } catch {
        await app.showError(error)
        return
      }
      if images.isEmpty {
        app.showStatus(tr("container.images.none"))
        return
      }
      // platform ごとに、空行で区切って並べる（Mac と同じ arm64、amd64 を先に）。複数の platform を持つイメージは、それぞれの組に出す。
      let all = Set(images.flatMap(\.platforms))
      let platforms = ["linux/arm64", "linux/amd64"].filter(all.contains) + all.subtracting(["linux/arm64", "linux/amd64"]).sorted()
      var labels: [String] = []
      var rows: [(name: String, platforms: [String])?] = []
      for platform in platforms {
        if !labels.isEmpty { labels.append(""); rows.append(nil) }
        // ほかのイメージの元になっているイメージには、それを元に作ったイメージの名前を添える（消すと作り直せなくなるため）。
        let derived = ContainerClient.derivedImages(layers, platform: platform)
        for image in images.filter({ $0.platforms.contains(platform) }).sorted(by: { $0.name < $1.name }) {
          let users = containers.filter { $0.details.image.map(ContainerClient.normalizedImage) == ContainerClient.normalizedImage(image.name) }
            .map(\.name).sorted()
          var label = "\(platform)  \(image.name)"
          if !users.isEmpty { label = tr("container.images.in_use", ["image": label, "names": users.joined(separator: ", ")]) }
          if let children = derived[image.name] {
            label = tr("container.images.base_of", ["image": label, "names": children.map(ContainerClient.shortImage).joined(separator: ", ")])
          }
          labels.append(label)
          rows.append(image)
        }
      }
      guard let index = await app.askChoice(tr("container.images.title"), labels), let chosen = rows[index] else { return }
      let image = chosen.name
      // platform を分けて消すことはできないので、複数あるときは全部消えることを書き添える。
      let message = chosen.platforms.count > 1
        ? tr("container.images.delete_confirm_platforms", ["image": image, "platforms": chosen.platforms.joined(separator: ", ")])
        : tr("container.images.delete_confirm", ["image": image])
      guard await app.confirm(tr("container.images.delete"), message) else { continue }
      do {
        let result = try await app.withProgress(tr("container.images.deleting")) { try await client.checked(["image", "rm", image]) }
        // 「Reclaimed 2.02 GB in disk space」のような、空いた容量の行を添える。
        let reclaimed = result.stdout.split(separator: "\n").last.map(String.init) ?? ""
        app.showStatus(tr("container.images.deleted", ["image": image, "detail": reclaimed]))
      } catch {
        await app.showError(error)
      }
    }
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
    if canShowMenu { keys[11] = ("Container", "") }
    return keys
  }

  override var commands: [Operation: Command] {
    if ssh != nil && found != nil {
      return super.commands
    }
    if ssh != nil {
      var result = super.commands
      result[.transfer] = ContainerTransfer(upload: false)
      return result
    }
    return [.enter: ContainerEnter(), .reload: ReloadCommand(), .extract: ContainerAction("start"),
      .shell: ContainerAction("stop"), .create: ContainerAction("create"),
      .delete: ContainerAction("delete"), .compose: ComposeFiles(), .chmod: ContainerSettingsCommand(), .logs: ContainerLogs()]
  }
  override var transferCommand: Command? { ContainerTransfer(upload: true) }

  override func allowsKey(_ id: String) -> Bool {
    if found != nil {
      return super.allowsKey(id)
    }
    if ssh == nil, id.hasPrefix("f"), let number = Int(id.dropFirst()) {
      guard (1...12).contains(number) else { return false }
      guard let keys = functionKeyLayout else { return false }
      return keys[number - 1] != nil
    }
    return super.allowsKey(id) || ["enter", "char:l", "char:u", "char:s", "char:c", "char:d", "ctrl:c", "char:a", "char: ", "char:　", "char:*", "delete", "f2", "f4"].contains(id)
  }

  func refreshContext() async {
    let root = NativeContainerProject.findRoot(localDirectory()) ?? localDirectory()
    if ssh == nil && filesDirectory != root { await load() }
  }

  override func fetch() async throws -> [Entry] {
    notice = nil
    serviceChecked = false
    if ssh != nil { return try await super.fetch() }
    guard #available(macOS 26, *) else { notice = [tr("container.requires_macos")]; return [] }
    guard FileManager.default.isExecutableFile(atPath: client.executable) else { notice = [tr("container.not_installed")]; return [] }
    serviceStopped = !(try await client.systemRunning())
    serviceChecked = true
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
    presentImages = (try? await client.imageNames()) ?? []
    defaultDNSDomain = await client.defaultDNSDomain()
    // 今のフォルダーの Dockerfile・Containerfile の見出しと行（by Status・by Network のどちらでも最後に出す）。
    let dockerfileSections = dockerfileSections()
    // 動いているコンテナ（設定にあるかを問わない）を up、今のフォルダーの設定（保存済みの設定か compose）にあるものを
    // down（作ってあって止まっている）・not created（まだ作っていない）に分け、
    // 最後に今のフォルダーの Dockerfile と Containerfile。設定にない止まっているコンテナは出さない（by Network で見る）。
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
    func missing(_ entry: Entry) -> Bool { (entry.data as? ContainerTarget)?.status == "missing" }
    func running(_ entry: Entry) -> Bool { (entry.data as? ContainerTarget)?.running == true }
    // by Network では、ネットワークの一覧のあとに、まだ作っていないもの（docker-compose）と Dockerfile・Containerfile を出す。
    if byNetwork {
      let notCreated = current.filter(missing)
      let title = tr("container.section.not_created")
      let compose = notCreated.isEmpty ? [] : [Entry(name: title, isDir: false, data: ContainerSection(title: title))] + notCreated
      if let composeError { app.showStatus(composeError) }
      return Self.spaced(try await networkEntries(containers) + compose + dockerfileSections)
    }
    var entries: [Entry] = []
    for (key, block) in [("up", current.filter(running) + other),
      ("down", current.filter { !running($0) && !missing($0) }),
      // まだ作っていないものは、イメージが手元にあるかによらず1つにまとめる（Enter で作るのは同じで、違うのは待ち時間だけ）。
      ("not_created", current.filter(missing))] where !block.isEmpty {
      let title = tr("container.section.\(key)")
      entries.append(Entry(name: title, isDir: false, data: ContainerSection(title: title)))
      entries += block
    }
    // 壊れた compose があっても、既存のコンテナには接続できる。
    if let composeError { app.showStatus(composeError) }
    return Self.spaced(entries + dockerfileSections)
  }

  /// 先頭以外の見出しの前に、空いた1行（見出しのない区切り）を入れる。
  private static func spaced(_ entries: [Entry]) -> [Entry] {
    var result: [Entry] = []
    for entry in entries {
      if !result.isEmpty, let section = entry.data as? ContainerSection, !section.title.isEmpty {
        result.append(Entry(name: "", isDir: false, data: ContainerSection(title: "")))
      }
      result.append(entry)
    }
    return result
  }

  /// 今のフォルダーの Dockerfile と Containerfile を、それぞれの見出しの下に並べた行。保存済みの設定がビルドに使っているものは重ねて出さない。
  private func dockerfileSections() -> [Entry] {
    let used = Set((nativeProject?.definitions ?? []).flatMap { definition in
      definition.prepare.filter { $0.first == "build" }.compactMap { step in step.firstIndex(of: "--file").flatMap { $0 + 1 < step.count ? step[$0 + 1] : nil } }
    }.map { p.normalize($0) })
    let here = localDirectory()
    let dockerfiles = ((try? FileManager.default.contentsOfDirectory(atPath: here)) ?? []).filter(DockerfileTarget.isDockerfile).sorted()
      .map { p.join(here, $0) }.filter { !used.contains(p.normalize($0)) }
    let targets = dockerfiles.map { path in
      let image = DockerfileTarget.imageName(path)
      return Entry(name: p.basename(path), isDir: false,
        data: DockerfileTarget(path: path, image: image, built: presentImages.contains(ContainerClient.normalizedImage(image))))
    }
    func containerfile(_ entry: Entry) -> Bool { (entry.data as? DockerfileTarget)?.isContainerfile == true }
    var entries: [Entry] = []
    for (key, block) in [("dockerfile", targets.filter { !containerfile($0) }), ("containerfile", targets.filter(containerfile))] where !block.isEmpty {
      let title = tr("container.section.\(key)")
      entries.append(Entry(name: title, isDir: false, data: ContainerSection(title: title)))
      entries += block
    }
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

  /// F12 の Shutdown。Apple Container のサービスを止める（動いているコンテナも止まる）。止めたあとは停止中の案内を出す。
  private func shutdown() async {
    do { try await app.withProgress(tr("container.stopping")) { try await client.stopSystem() } }
    catch { await app.showError(error) }
    await load()
  }

  /// Enter は、サービス停止中の案内からは、確認せずにサービスを起動する。
  func enter() async {
    if serviceStopped {
      await startService()
    } else if let current { await open(current) }
  }

  /// Apple Container のサービスを起動して、一覧を読み直す（確認はしない）。
  private func startService() async {
    do { try await app.withProgress(tr("container.starting")) { try await client.startSystem() } }
    catch { await app.showError(error) }
    await load()
  }

  /// 反対側のローカルの窓の G・F12 で開くメニュー。サービスが止まっていれば起動、動いていれば Shutdown だけを出す。
  func showServiceMenu() async {
    guard ssh == nil, serviceChecked, !loading else { return }
    let item = tr(serviceStopped ? "container.start_service" : "container.shutdown")
    guard await app.askChoice(tr("container.menu.title"), [item]) != nil else { return }
    if serviceStopped { await startService() } else { await shutdown() }
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
        // D では、イメージだけの行（未作成のコンテナ・ビルド済みの Dockerfile）のイメージも消す。同じイメージは1回だけ。
        var imageJobs: [(marks: [Mark], image: String)] = []
        if action == "delete" {
          for mark in targets {
            guard let image = imageOnly(mark.entry) else { continue }
            if let index = imageJobs.firstIndex(where: { $0.image == image }) { imageJobs[index].marks.append(mark) }
            else { imageJobs.append(([mark], image)) }
          }
        }
        guard !jobs.isEmpty || !imageJobs.isEmpty else { app.showStatus(tr("container.no_action_targets")); return }
        // 起動（U）はすぐ実行する。停止・破棄だけ確かめる。
        if action != "start" {
          let messageKey = action == "delete" ? "container.bulk_delete_confirm" : "container.bulk_stop_confirm"
          var sections: [String] = []
          if !jobs.isEmpty { sections.append(tr(messageKey) + "\n\n" + jobs.map { $0.1.name }.joined(separator: "\n")) }
          if !imageJobs.isEmpty { sections.append(tr("container.bulk_delete_images_confirm") + "\n\n" + imageJobs.map(\.image).joined(separator: "\n")) }
          guard await app.confirm(tr("container.\(action)"), sections.joined(separator: "\n\n"), yes: tr("container.\(action)")) else { return }
        }
        // Esc で中止したら、残りは実行しない（止めたコマンドの失敗も知らせない）。
        try await app.withProgress(tr("container.progress_action")) {
          for (mark, target) in jobs {
            if Task.isCancelled { break }
            do {
              if action == "start" {
                let ports = existing.first { $0.name == target.name }?.details.ports ?? []
                let conflicts = try await portConflicts(publishing: ports, container: target.name)
                if !conflicts.isEmpty { errors.append(portConflictMessage(target.name, conflicts)); continue }
              }
              try await client.checked([action, target.name])
              marks.removeValue(forKey: keyOf(mark.entry))
            } catch { if !Task.isCancelled { errors.append("\(target.name): \(errorMessage(error))") } }
          }
          for (imageMarks, image) in imageJobs {
            if Task.isCancelled { break }
            do {
              try await client.checked(["image", "rm", image])
              for mark in imageMarks { marks.removeValue(forKey: keyOf(mark.entry)) }
            } catch { if !Task.isCancelled { errors.append("\(image): \(errorMessage(error))") } }
          }
        }
      }
    } catch is CancellationError {
      app.showStatus(tr("dialogs.aborted"))
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

  /// F12 の Create a new Containerfile / Modify the Containerfile。今のフォルダーの Containerfile の項目を小窓で決めて書き、その行にカーソルを置く。
  /// すでにあれば、その中身を小窓に読み込んで更新する（小窓で扱わない行は残す）。
  /// ビルドと作成は、ほかの Containerfile と同じく Enter で行う。
  func createContainerfile() async {
    let directory = localDirectory()
    let path = p.join(directory, "Containerfile")
    let original: String?
    do {
      original = FileManager.default.fileExists(atPath: path) ? try String(contentsOfFile: path, encoding: .utf8) : nil
    } catch {
      await app.showError(error)
      return
    }
    let file = Containerfile(original ?? "")
    // 新しく作るときの初期値。TZ を効かせるには、イメージに tzdata（タイムゾーンのデータ）が要る。
    var settings = original == nil
      ? ContainerfileSettings(packages: ["tzdata", "curl", "git"], timezone: "Asia/Tokyo", language: "ja_JP", charset: "UTF-8", workdir: "/work",
        ports: ["30080/tcp", "30443/tcp", "30022/tcp"])
      : file.settings
    // Platform と元のイメージは、ローカルにあるイメージの一覧から選んで小窓を開き直す。元のイメージは、選んだ platform を持つものだけを出す。
    // どちらかが空のまま決めたら、知らせてから入れた内容のまま小窓に戻す。
    var row = 0
    while true {
      let current = settings
      let currentRow = row
      guard let chosen: ContainerfileDialog.Choice = await app.showModal({ close in
        ContainerfileDialog(path, current, isNew: original == nil, row: currentRow, close)
      }) else { return }
      switch chosen {
      case .choosePlatform(let value), .chooseImage(let value):
        settings = value
        let choosingPlatform: Bool
        if case .choosePlatform = chosen { choosingPlatform = true } else { choosingPlatform = false }
        row = choosingPlatform ? ContainerfileDialog.platformRow : ContainerfileDialog.imageRow
        let local: [(name: String, platforms: [String])]
        let platforms: [String]
        do {
          local = try await client.imagePlatforms()
          // Platform は、ローカルのイメージによらず、この Mac で動かせるもの（Mac の CPU と、Rosetta が有効なら amd64）。
          platforms = choosingPlatform ? try await client.runnablePlatforms() : []
        } catch { await app.showError(error); continue }
        if choosingPlatform {
          guard let index = await app.askChoice(tr("container.containerfile.choose_platform_title"), platforms) else { continue }
          // 元のイメージがその platform を持たなければ、選び直してもらう。
          if settings.platform != platforms[index],
            !local.contains(where: { ContainerClient.shortImage($0.name) == settings.image && $0.platforms.contains(platforms[index]) }) {
            settings.image = ""
          }
          settings.platform = platforms[index]
          row = ContainerfileDialog.imageRow
          continue
        }
        let images = local.filter { $0.platforms.contains(settings.platform) }.map { ContainerClient.shortImage($0.name) }.sorted()
        if images.isEmpty {
          app.showStatus(tr("container.containerfile.no_platform_images", ["platform": settings.platform]))
          continue
        }
        guard let index = await app.askChoice(tr("container.containerfile.choose_image_title", ["platform": settings.platform]), images) else { continue }
        settings.image = images[index]
        // 新しく作るときは、Debian 系（apt）のイメージなら、debconf の質問でビルドが止まらないよう環境変数の初期値に入れておく。
        if original == nil {
          let noninteractive = "DEBIAN_FRONTEND=noninteractive"
          settings.environment.removeAll { $0 == noninteractive }
          if PackageManager.of(settings.image) == .apt { settings.environment.insert(noninteractive, at: 0) }
        }
        // 選んだら、次の項目へ進める。
        row = ContainerfileDialog.imageRow + 1
        continue
      case .apply(let value):
        settings = value
      }
      if settings.platform.isEmpty {
        row = ContainerfileDialog.platformRow
        app.showStatus(tr("container.containerfile.platform_required"))
        continue
      }
      if !settings.image.isEmpty { break }
      row = ContainerfileDialog.imageRow
      app.showStatus(tr("container.containerfile.image_required"))
    }
    let text = file.text(settings)
    if text != original {
      do {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
      } catch {
        await app.showError(error)
        return
      }
    }
    await reloadLocal()
    await load(focus: "Containerfile")
    if original == nil { app.showStatus(tr("container.containerfile.created")) }
    else if text != original { app.showStatus(tr("container.containerfile.updated")) }
  }

  /// 設定窓を開き、決めた設定を返す。Mac 側のポートがほかで使われていれば、知らせてから設定窓に戻す。
  /// ビルドして作る設定なら、その Dockerfile・Containerfile の（最後のステージの）FROM のイメージと --platform（なければ空）。読めなければ nil。
  private func baseImage(_ definition: NativeContainerDefinition) -> (image: String, platform: String)? {
    guard let build = definition.prepare.first(where: { $0.first == "build" }), let context = build.last else { return nil }
    let root = nativeProject?.root ?? localDirectory()
    var file = build.firstIndex(of: "--file").flatMap { $0 + 1 < build.count ? build[$0 + 1] : nil } ?? p.join(context, "Dockerfile")
    if !p.isAbsolute(file) { file = p.join(root, file) }
    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
    let settings = Containerfile(text).settings
    return settings.image.isEmpty ? nil : (settings.image, settings.platform)
  }

  /// Dockerfile・Containerfile から作るときは、イメージの行に FROM のイメージを出す。
  /// [fillPlatform]（作成するとき）なら、Platform が空のときにそのイメージの platform を入れる。
  private func askSettings(_ name: String, _ definition: NativeContainerDefinition, fillPlatform: Bool = false) async throws -> NativeContainerDefinition? {
    var settings = ContainerSettings(definition)
    let base = baseImage(definition)
    // FROM に --platform があればそれを、なければローカルにある元のイメージの platform を入れる。
    if fillPlatform, let base, settings.platform.isEmpty {
      if !base.platform.isEmpty { settings.platform = base.platform }
      else if let platform = await client.preferredPlatform(base.image) { settings.platform = platform }
    }
    let baseImage = base?.image
    // 作成するときは、ネットワークを指定していなければ、ネットワークなし（none）から始める。
    if fillPlatform && settings.networks.isEmpty { settings.networks = ["none"] }
    var row = 0
    while true {
      let current = settings
      let currentRow = row
      guard let choice: ContainerSettingsDialog.Choice = await app.showModal({ close in
        ContainerSettingsDialog(name, current, baseImage: baseImage, row: currentRow, close)
      }) else { return nil }
      let edited: ContainerSettings
      switch choice {
      case .chooseNetwork(let value):
        settings = value
        row = ContainerSettingsDialog.networksRow
        if let chosen = await chooseNetworks(settings.networks) { settings.networks = chosen }
        continue
      case .apply(let value):
        edited = value
      }
      let updated = try edited.applied(to: definition).withDefaults()
      let conflicts = try await portConflicts(updated.create, container: name)
      if conflicts.isEmpty { return updated }
      await app.showError(tr("container.port_conflict", ["ports": conflicts.joined(separator: "\n")]) + "\n" + tr("container.port_change_hint"))
      settings = edited
    }
  }

  /// none（ネットワークなし）・default と今あるネットワークから、つなぐものを選ぶ。Space で [x] を切り替え、Enter で決める（Esc は変更ごとやめる）。
  /// none はほかと一緒には選べない。返すのは --network の値で、default だけなら空（--network を付けない）。
  private func chooseNetworks(_ current: [String]) async -> [String]? {
    let known = (try? await client.networks()) ?? []
    let names = ["none", "default"] + known.map(\.name).filter { $0 != "default" }.sorted()
    let labels = names.map { name in known.first { $0.name == name && !$0.subnet.isEmpty }.map { "\(name)  \($0.subnet)" } ?? name }
    let initial = Set((current.isEmpty ? ["default"] : current).compactMap { names.firstIndex(of: $0) })
    let none = 0
    guard let checked: Set<Int> = await app.showModal({ close in
      CheckListDialog(tr("container.info.networks"), labels, checked: initial, toggle: { index, checked in
        if checked.contains(index) { return checked.subtracting([index]) }
        return index == none ? [none] : checked.subtracting([none]).union([index])
      }, close)
    }) else { return nil }
    // 何も選ばなければ default。並びは一覧の順にする。
    let ordered = names.indices.filter(checked.contains).map { names[$0] }
    return ordered.isEmpty || ordered == ["default"] ? [] : ordered
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
      guard let definition = try await askSettings(name, prepared, fillPlatform: true) else { return }
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
        + configuration.file(definition)
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

  /// 重ねる Compose ファイルを、一覧から重ねる順に1つずつ選ぶ（Ctrl+C）。何も選ばずに決めると自動の選び方に戻る。
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

  /// 右端の列に出すもの。コンテナは、Mac やほかのコンテナから引ける「コンテナ名.ドメイン」（ドメインがなければ出さない）。
  /// 作ったコンテナは Apple Container の一覧のドメイン、まだ作っていないものは設定の --dns-domain（なければ既定のドメイン）。
  /// Dockerfile・Containerfile には出さない（作るイメージの名前は、作成の設定窓で決める）。
  private func detailOf(_ entry: Entry) -> String {
    guard let target = entry.data as? ContainerTarget else { return "" }
    let domain = target.details.dnsDomain ?? (target.status == "missing" ? defaultDNSDomain : nil)
    return domain.map { "\(target.name).\($0)" } ?? ""
  }

  /// 名前を左に、コンテナ名.ドメインを右端に寄せて描く（ほかのタブのサイズ・日時と同じ並び）。
  /// by Network では、その左に状態（running など）も出す。by Status ではブロックで状態が分かるので出さない。
  /// 狭い窓ではコンテナ名.ドメインの列を省く。
  override func drawRow(_ screen: Screen, _ entry: Entry, _ x: Int, _ y: Int, _ width: Int, _ style: Style, marked: Bool) {
    if let section = entry.data as? ContainerSection {
      // 見出しのない区切りは、空いた1行にする。
      if section.title.isEmpty { return }
      let line = "── \(section.title) " + String(repeating: "─", count: max(0, width - textWidth(section.title) - 5))
      screen.text(x + 1, y, truncate(line, max(0, width - 1)), style.copyWith(fg: colors.muted, bold: true), maxWidth: max(0, width - 1))
      return
    }
    if entry.data is DockerfileTarget {
      drawColumns(screen, entry.name, nil, detailOf(entry), x, y, width, style, highlight: false, marked: marked)
      return
    }
    guard let target = entry.data as? ContainerTarget else { super.drawRow(screen, entry, x, y, width, style, marked: marked); return }
    // まだ作っていないもの（docker-compose の見出しの下）は、状態を出さない。
    let status = byNetwork && target.status != "missing" ? target.status : nil
    drawColumns(screen, entry.name, status, detailOf(entry), x, y, width, style, highlight: target.running, marked: marked)
  }

  /// [status] が nil なら状態の列を作らない。
  private func drawColumns(_ screen: Screen, _ name: String, _ status: String?, _ detail: String,
    _ x: Int, _ y: Int, _ width: Int, _ style: Style, highlight: Bool, marked: Bool) {
    let contentWidth = max(0, width - 3)
    guard contentWidth > 0 else { return }
    let statusWidth = status == nil ? 0 : min(9, max(0, contentWidth - 5))
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
    if statusWidth > 0, let status {
      let status = truncate(status, statusWidth)
      let statusEnd = end - (detailWidth > 0 ? detailWidth + 1 : 0)
      screen.text(statusEnd - textWidth(status), y, status, rowStyle, maxWidth: statusWidth)
    }
  }
}
