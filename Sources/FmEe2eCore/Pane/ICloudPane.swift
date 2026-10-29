import Foundation

enum ICloudState { case checking, notAvailable, unreadable, ready }

/// iCloud Drive の窓。この Mac の iCloud Drive のフォルダー（~/Library/Mobile Documents/com~apple~CloudDocs）を
/// ルートにしたローカルの窓で、そこより上には行かない。右のタブに出し、G・F12 で左のローカルとの間でコピーする。
final class ICloudPane: LocalPane {
  var state = ICloudState.checking

  /// フォルダーを読めなかった理由。
  private var problem: String?

  /// iCloud Drive のフォルダー。
  static var root: String { p.join(homeDir, "Library", "Mobile Documents", "com~apple~CloudDocs") }

  override var commands: [Operation: Command] {
    state != .ready
      ? [.enter: ReloadCommand(), .reload: ReloadCommand()]
      : [
        .enter: EnterCommand(),
        .reload: ReloadCommand(),
        .delete: LocalDelete(),
        .chmod: LocalChmod(),
        .touch: LocalTouch(),
        .mkdir: LocalMkdir(),
        .rename: LocalRename(),
        .edit: PathEdit(),
        .paste: LocalPaste(),
        .compress: LocalCompress(),
        .extract: LocalExtract(),
        .toggleHidden: ToggleHiddenCommand(),
        // 右の iCloud Drive のタブで G・F12 は、左のローカルへのダウンロード。
        .transfer: ICloudDownload(),
      ]
  }

  /// 右に iCloud Drive を出しているとき、左のタブで G・F12 を押すと、左のローカルからアップロードする。
  override var transferCommand: Command? { ICloudUpload() }

  override var title: String { "iCloud Drive" }

  /// iCloud Drive からの位置。
  override var location: String {
    if state != .ready {
      return ""
    }
    let relative = p.relative(super.location, from: Self.root)
    return relative == "." ? title : "\(title) / \(p.split(relative).joined(separator: " / "))"
  }

  override var accent: Rgb { Palette.lime }

  override var placeholder: [String]? {
    switch state {
    case .checking: ["確認中…"]
    case .notAvailable: ["iCloud Driveは使えません。", "この Mac のシステム設定で iCloud Drive をオンにしてください。"]
    case .unreadable: ["iCloud Driveのフォルダーを読めません。", ""] + (problem.map { [$0] } ?? []) + ["", "直したら L で確かめ直します。"]
    case .ready: nil
    }
  }

  /// iCloud Drive のフォルダーを確かめ、読めれば一覧を読む（起動時と L）。
  func check() async {
    state = .checking
    problem = nil
    app.requestRender()
    let dir = Self.root
    var isDir: ObjCBool = false
    if !FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) || !isDir.boolValue {
      setState(.notAvailable)
      return
    }
    guard let handle = opendir(dir) else {
      setState(.unreadable, problem: String(cString: strerror(errno)))
      return
    }
    closedir(handle)
    state = .ready
    await goTo(dir)
  }

  private func setState(_ next: ICloudState, problem: String? = nil) {
    state = next
    self.problem = problem
    entries = []
    marks.clear()
    usage = nil
    app.requestRender()
  }

  override func reload() async {
    if state == .ready {
      await super.reload()
    } else {
      await check()
    }
  }

  override func fetch() async throws -> [Entry] { state == .ready ? try await super.fetch() : [] }

  override func fetchUsage() async throws -> DiskUsage? { state == .ready ? try await super.fetchUsage() : nil }

  override var canGoUp: Bool { inArchive || (state == .ready && dir != Self.root) }

  /// iCloud Drive の外へは出ない。
  override func goTo(_ target: String, focus: String? = nil) async {
    if target == Self.root || p.isWithin(Self.root, target) {
      await super.goTo(target, focus: focus)
    }
  }

  override func up() async {
    if canGoUp {
      await super.up()
    }
  }
}
