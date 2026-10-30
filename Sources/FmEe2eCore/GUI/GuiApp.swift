import AppKit

/// GUI 版を起動する。終わったら終了する（戻らない）。
public func runFmEe2eGUI() -> Never {
  importLoginEnvironment()
  // Finder や Dock から起動すると、今いるフォルダーが / になる。左の窓は今いるフォルダーで始まるので、
  // 前回終了したときの左のローカルのフォルダー（なくなっていればホーム）にする。
  if FileManager.default.currentDirectoryPath == "/" {
    let last = GuiState.load().lastLocalDir
    var isDir: ObjCBool = false
    let usable = last.map { FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue } ?? false
    FileManager.default.changeCurrentDirectoryPath(usable ? last! : NSHomeDirectory())
  }
  let application = NSApplication.shared
  application.setActivationPolicy(.regular)
  let delegate = GuiAppDelegate()
  application.delegate = delegate
  withExtendedLifetime(delegate) {
    application.run()
  }
  exit(0)
}

/// 窓を作り、メイン画面を出す。
private final class GuiAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private var window: NSWindow?

  /// 終了する（⌘Q・窓を閉じる・メニューや Dock の終了）。
  private var requestQuit: (() -> Void)?

  private var host: GuiHost?
  private var main: MainView?

  /// 窓の後ろをぼかす view（appearance.window.blur）。
  private var blurView: NSVisualEffectView?

  /// 最後に読んだ設定ファイルの中身（なければ nil）。前面に戻ったとき、これと比べて変わっていれば読み直す。
  private var configData: Data?

  /// 最後に読んだ文言のファイルの中身。設定ファイルと同じく、変わっていれば読み直す。
  private var stringsData: Data?

  /// 今の画面の言葉（設定の language）。
  private var language = "ja"

  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { await start() }
  }

  /// 前面に戻るたびに、設定ファイルが変わっていれば読み直して反映する。
  func applicationDidBecomeActive(_ notification: Notification) {
    reloadConfigIfChanged()
  }

  private func start() async {
    // 設定ファイルの誤りの文も文言のファイルから作るので、先に日本語を読み、設定の言葉が違えば読み直す。
    var stringsError = Strings.load(language)
    configData = FileManager.default.contents(atPath: AppConfig.file)
    let (config, loadError) = await loadConfig()
    if config.language != language {
      language = config.language
      stringsError = Strings.load(language)
    }
    stringsData = FileManager.default.contents(atPath: Strings.file(language))
    // メニューの文言は文言のファイルから作るので、読んでから作る。
    NSApplication.shared.mainMenu = makeMainMenu()
    let configError = [stringsError, loadError].compactMap { $0 }.joined(separator: "\n\n")
    Appearance.current = config.appearance
    let host = GuiHost()
    self.host = host
    let window = makeWindow(host)
    self.window = window
    var shown: MainView?
    await runMain(host, config, configError.isEmpty ? nil : configError) { main in
      shown = main
      self.main = main
      requestQuit = { Task { await main.quit() } }
    }
    if let shown {
      GuiState(lastLocalDir: shown.local.dir).save()
    }
    exit(0)
  }

  private func makeWindow(_ host: GuiHost) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "fm-ee2e-swift"
    // 背景を、タイトルバーの下まで描く。
    window.titlebarAppearsTransparent = true
    window.appearance = NSAppearance(named: .darkAqua)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.delegate = self
    window.center()
    window.setFrameAutosaveName("fm-ee2e-main")
    let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
    container.autoresizingMask = [.width, .height]
    let effect = NSVisualEffectView(frame: container.bounds)
    effect.autoresizingMask = [.width, .height]
    effect.material = .underWindowBackground
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.isHidden = !Appearance.current.blur
    container.addSubview(effect)
    blurView = effect
    let view = GridView(host)
    view.frame = container.bounds
    view.autoresizingMask = [.width, .height]
    container.addSubview(view)
    host.view = view
    window.contentView = container
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)
    NSApp.activate()
    return window
  }

  /// 設定ファイル・文言のファイルが前回読んだときから変わっていれば、読み直して反映する。
  /// 設定ファイルを読めなければエラーを出し、今の設定のままにする。
  private func reloadConfigIfChanged() {
    guard let host, let main else { return }
    var languageChanged = false
    let data = FileManager.default.contents(atPath: AppConfig.file)
    if data != configData {
      configData = data
      do {
        // ファイルがなくなったときは、既定の設定にする。
        let config = try AppConfig.parse(data ?? Data())
        Appearance.current = config.appearance
        blurView?.isHidden = !config.appearance.blur
        host.appearanceChanged()
        main.apply(config)
        showMissingFonts(main.app, config.appearance)
        languageChanged = config.language != language
        language = config.language
      } catch {
        Task { await main.app.showError(tr("gui_app.config_reload_failed", ["error": errorMessage(error)])) }
      }
    }
    let strings = FileManager.default.contents(atPath: Strings.file(language))
    if languageChanged || strings != stringsData {
      stringsData = strings
      if let error = Strings.load(language) {
        Task { await main.app.showError(error) }
      }
      NSApplication.shared.mainMenu = makeMainMenu()
      main.app.requestRender()
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let requestQuit else {
      return .terminateNow
    }
    requestQuit()
    return .terminateCancel
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    requestQuit?()
    return false
  }

  /// このアプリをもう1つ起動して、新しい窓を開く（メニューの「fm-ee2e-swift を開く」・⌘S）。
  @objc func openNewInstance(_ sender: Any?) {
    let bundle = Bundle.main.bundleURL
    if bundle.pathExtension == "app" {
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.createsNewApplicationInstance = true
      NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
    } else if let executable = Bundle.main.executableURL {
      // .app にまとめずに動かしているとき（swift run など）は、実行ファイルをそのまま起動する。
      _ = try? Process.run(executable, arguments: [])
    }
  }
}

private func makeMainMenu() -> NSMenu {
  let main = NSMenu()
  func submenu(_ title: String, _ items: [NSMenuItem]) {
    let item = NSMenuItem()
    let menu = NSMenu(title: title)
    for child in items {
      menu.addItem(child)
    }
    item.submenu = menu
    main.addItem(item)
  }
  func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
    NSMenuItem(title: title, action: action, keyEquivalent: key)
  }
  submenu(
    "fm-ee2e-swift",
    [
      item(tr("gui_app.menu.open"), #selector(GuiAppDelegate.openNewInstance(_:)), "s"),
      .separator(),
      item(tr("gui_app.menu.quit"), #selector(NSApplication.terminate(_:)), "q"),
    ]
  )
  submenu(
    tr("gui_app.menu.edit"),
    [
      item(tr("gui_app.menu.copy"), #selector(GridView.copy(_:)), "c"),
      item(tr("gui_app.menu.paste"), #selector(GridView.paste(_:)), "v"),
      item(tr("gui_app.menu.select_all"), #selector(GridView.selectAll(_:)), "a"),
    ]
  )
  submenu(
    tr("gui_app.menu.view"),
    [
      item(tr("gui_app.menu.zoom_in"), #selector(GridView.zoomIn(_:)), "+"),
      item(tr("gui_app.menu.zoom_out"), #selector(GridView.zoomOut(_:)), "-"),
      item(tr("gui_app.menu.zoom_reset"), #selector(GridView.zoomReset(_:)), "0"),
    ]
  )
  submenu(
    tr("gui_app.menu.window"),
    [
      item(tr("gui_app.menu.minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
      item(tr("gui_app.menu.close"), #selector(NSWindow.performClose(_:)), "w"),
    ]
  )
  return main
}

/// Finder などから起動すると、ログインシェルで設定した環境変数（PATH・EDITOR・LANG など）がないので、
/// ログインシェルから読み込む。端末から起動したとき（TERM がある）はそのまま使う。
private func importLoginEnvironment() {
  let environment = ProcessInfo.processInfo.environment
  if environment["TERM"] == nil {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: environment["SHELL"] ?? "/bin/zsh")
    let marker = "__FM_EE2E_ENV__"
    process.arguments = ["-l", "-i", "-c", "printf '%s' \(marker); /usr/bin/env -0"]
    let output = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    if (try? process.run()) != nil {
      // シェルの設定が止まっても待ち続けない。
      DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
        if process.isRunning {
          process.terminate()
        }
      }
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      let text = String(decoding: data, as: UTF8.self)
      if let range = text.range(of: marker) {
        for entry in text[range.upperBound...].split(separator: "\0") {
          guard let equal = entry.firstIndex(of: "=") else { continue }
          let name = String(entry[..<equal])
          if ["PWD", "OLDPWD", "SHLVL", "_", "TERM"].contains(name) {
            continue
          }
          setenv(name, String(entry[entry.index(after: equal)...]), 1)
        }
      }
    }
  }
  // vim などが日本語を正しく扱えるよう、ターミナル.app と同じく UTF-8 のロケールにする。
  if ProcessInfo.processInfo.environment["LANG"] == nil {
    let language = Locale.current.language
    let code = [language.languageCode?.identifier, language.region?.identifier].compactMap { $0 }.joined(separator: "_")
    setenv("LANG", (code.contains("_") ? code : "en_US") + ".UTF-8", 1)
  }
}

/// 終了したときの状態。~/Library/Application Support/fm-ee2e/state.json に置く。
private struct GuiState: Codable {
  /// 左のローカルの窓で開いていたフォルダー。
  var lastLocalDir: String?

  enum CodingKeys: String, CodingKey {
    case lastLocalDir = "last_local_dir"
  }

  private static var file: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("fm-ee2e").appendingPathComponent("state.json")
  }

  /// 読めなければ空の状態。
  static func load() -> GuiState {
    guard let file, let data = try? Data(contentsOf: file), let state = try? JSONDecoder().decode(GuiState.self, from: data) else {
      return GuiState()
    }
    return state
  }

  /// 書けなくても終了は止めない。
  func save() {
    guard let file = Self.file else { return }
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    try? encoder.encode(self).write(to: file, options: .atomic)
  }
}
