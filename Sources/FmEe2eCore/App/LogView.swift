import Foundation

/// 全画面の一覧（コミットの一覧・ファイルの一覧）の共通部分。上の帯・カーソル・スクロール・下の案内。
/// （継承する側がこのファイルの外からも見えるので、internal にしている）
class LogListView: Modal {
  init(_ app: App, _ close: @escaping (()) -> Void, _ title: String) {
    self.app = app
    self.close = close
    super.init(title, accent: Appearance.current.theme(.git).colors.accent(or: \.orange))
  }

  /// git のタブの見た目で描く。
  override var themeKey: ThemeKey { .git }

  let app: App
  let close: (()) -> Void
  var cursor = 0
  fileprivate var scroll = 0

  /// 操作中（次の画面を開く準備など）。その間のキーは無視する。
  fileprivate var busy = false

  var length: Int { 0 }

  /// 一覧が空のときの案内。
  var empty: String { "" }

  func drawRow(_ screen: Screen, _ y: Int, _ w: Int, _ index: Int, _ style: Style) {}

  /// Enter で開けるか。
  var openable: Bool { true }

  /// カーソルの項目（マークが1つだけならその項目）で Enter を押したとき。
  func open(_ index: Int) async throws {}

  /// Space でマークできるか。
  var markable: Bool { false }

  /// マークした項目の番号。一覧を読み直したら消す。
  var marks: Set<Int> = []

  /// 2つ以上マークして Enter を押したとき。[first] と [last] は、マークした項目の番号の最小と最大。
  func openRange(_ first: Int, _ last: Int) async throws {}

  /// E で、カーソルの項目を直せるか。
  var editable: Bool { false }

  /// カーソルの項目で E を押したとき（[editable] のときだけ）。
  func edit(_ index: Int) async throws {}

  /// D で消せるか。
  var deletable: Bool { false }

  /// D を押したとき（[deletable] のときだけ）。[indices] は、マークした項目（なければカーソルの項目）の番号。
  func delete(_ indices: [Int]) async throws {}

  /// 上の帯の見出し。一覧を読み直すと変わることがある。
  var heading: String { title }

  override func drawTitle(_ screen: Screen, _ x: Int, _ y: Int, _ width: Int) {
    screen.text(x, y, truncate(heading, width), Modal.bar.copyWith(fg: titleColor, bold: true))
  }

  override var frame: ModalFrame { .page }

  override var hints: [(String, String)] {
    [("↑↓ PgUp PgDn", tr("log_view.hints.move"))]
      + (markable ? [("Space", tr("log_view.hints.mark"))] : [])
      + (openable ? [("Enter", tr("log_view.hints.open"))] : [])
      + (editable ? [("E", tr("log_view.hints.edit"))] : [])
      + (deletable ? [("D", tr("log_view.hints.delete"))] : [])
      + [("Esc / q", tr("log_view.hints.back"))]
  }

  /// [action] を実行し、その間のキーは無視する。失敗したらエラーを出す。
  private func start(_ action: @escaping () async throws -> Void) {
    busy = true
    Task {
      do {
        try await action()
      } catch {
        await app.showError(error)
      }
      busy = false
      app.requestRender()
    }
  }

  override func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ width: Int) {
    cursor = min(max(cursor, 0), max(0, length - 1))
    scroll = fitScroll(cursor: cursor, scroll: scroll, length: length, rows: bodyRows)
    if length == 0 {
      screen.text(x + 2, y + 1, empty, background.copyWith(fg: Palette.muted))
    }
    var i = 0
    while i < bodyRows && scroll + i < length {
      let index = scroll + i
      let style = index == cursor ? background.copyWith(bg: Palette.orangeDark) : background
      screen.fill(x, y + i, width, 1, style)
      if marks.contains(index) {
        screen.text(x, y + i, "*", style.copyWith(fg: Palette.lime, bold: true))
      }
      drawRow(screen, y + i, width, index, style)
      i += 1
    }
  }

  override func handleKey(_ key: Key) {
    if busy {
      return
    }
    switch key.name {
    case "up":
      cursor -= 1
    case "down":
      cursor += 1
    case "pageUp":
      cursor -= bodyRows
    case "pageDown":
      cursor += bodyRows
    case "home":
      cursor = 0
    case "end":
      cursor = length - 1
    case "escape":
      close(())
    case "enter":
      if openable && length > 0 {
        let marked = marks.sorted()
        let index = marked.count == 1 ? marked[0] : cursor
        start { [unowned self] in
          if marked.count >= 2 {
            try await openRange(marked.first!, marked.last!)
          } else {
            try await open(index)
          }
        }
      }
    case "char":
      // 日本語入力がオンのままだと、Space は全角スペースで届く。
      if markable && length > 0 && (key.char == " " || key.char == "　") {
        if marks.remove(cursor) == nil {
          marks.insert(cursor)
        }
        cursor += 1
      } else if key.char!.lowercased() == "q" {
        close(())
      } else if key.char!.lowercased() == "e" && editable && length > 0 {
        let index = cursor
        start { [unowned self] in try await edit(index) }
      } else if key.char!.lowercased() == "d" && deletable && length > 0 {
        let indices = marks.isEmpty ? [cursor] : marks.sorted()
        start { [unowned self] in try await delete(indices) }
      }
    default:
      break
    }
    cursor = min(max(cursor, 0), max(0, length - 1))
  }
}

/// コミット [hash] の作者（名前・メールアドレス）とメッセージを聞いて書き換える。書き換えたら true。
/// 署名されたコミット（あとに続くものを含む）は書き換えない。push 済みなら確かめる。
private func editCommit(_ app: App, _ git: Git, _ root: String, _ hash: String) async throws -> Bool {
  let rewrite = try await app.withProgress(tr("log_view.running", ["command": "git cat-file"])) { try await git.prepareAuthorRewrite(root, hash) }
  if rewrite.signed != nil {
    app.showStatus(tr("log_view.edit.signed"))
    return false
  }
  let (oldName, oldEmail) = rewrite.target.author
  let oldMessage = rewrite.target.message
  // 名前とメールアドレスには、git が区切りに使う < > と改行は使えない。
  func check(_ value: String, _ what: String) -> String? {
    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? tr("log_view.edit.required", ["what": what])
      : value.unicodeScalars.contains(where: { $0 == "<" || $0 == ">" || $0 == "\n" })
      ? tr("log_view.edit.no_angle_brackets", ["what": what])
      : nil
  }
  guard
    let name = (await app.input(tr("log_view.edit.author_name"), initial: oldName, validate: { check($0, tr("log_view.edit.name")) }))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  else {
    return false
  }
  guard
    let email = (await app.input(tr("log_view.edit.author_email"), initial: oldEmail, validate: { check($0, tr("log_view.edit.email")) }))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  else {
    return false
  }
  let message = (await app.input(
    tr("log_view.edit.message"),
    initial: oldMessage,
    allowNewlines: true,
    validate: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? tr("log_view.edit.message_required") : nil }
  )).map(trimRight)
  guard let message, !(same(name, oldName) && same(email, oldEmail) && same(message, oldMessage)) else {
    return false
  }
  let later = rewrite.after.count
  if try await app.withProgress(tr("log_view.running", ["command": "git branch"]), { try await git.isPushed(root, hash) }),
    !(await app.confirm(
      tr("log_view.edit.rewrite_title"),
      tr("log_view.edit.pushed") + "\n"
        + (later == 0 ? "" : tr("log_view.edit.later", ["count": later]) + "\n")
        + tr("log_view.edit.continue"),
      yes: tr("log_view.edit.rewrite_yes")
    ))
  {
    return false
  }
  try await app.withProgress(tr("log_view.edit.rewriting")) {
    try await git.rewriteAuthor(root, rewrite, name: name, email: email, message: same(message, oldMessage) ? nil : message)
  }
  return true
}

/// 符号の並びが同じか（正準等価では比べない）。
private func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

/// 後ろの空白を除く。
private func trimRight(_ s: String) -> String {
  var scalars = Substring(s).unicodeScalars
  while let last = scalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
    scalars.removeLast()
  }
  return String(scalars)
}

/// 今のブランチのコミットの一覧。Enter で、そのコミットで変わったファイルの一覧を出す。
final class LogView: LogListView {
  init(_ app: App, _ close: @escaping (()) -> Void, _ git: Git, _ root: String, _ branch: String, _ commits: [GitCommit]) {
    self.git = git
    self.root = root
    self.branch = branch
    self.commits = commits
    super.init(app, close, "git log  \(branch)")
  }

  let git: Git
  let root: String
  let branch: String
  var commits: [GitCommit]

  override var heading: String { tr("log_view.heading_count", ["title": title, "count": commits.count]) }

  override var length: Int { commits.count }

  override var editable: Bool { true }

  override func edit(_ index: Int) async throws {
    if try await editCommit(app, git, root, commits[index].hash) {
      commits = try await app.withProgress(tr("log_view.running", ["command": "git log"])) { try await git.log(root) }
      marks.removeAll()
    }
  }

  override var markable: Bool { true }

  /// 一覧は新しい順なので、[first] が一番新しく、[last] が一番古い。
  override func openRange(_ first: Int, _ last: Int) async throws {
    let (app, git, root) = (app, git, root)
    let newest = commits[first]
    let oldest = commits[last]
    let files = try await app.withProgress(tr("log_view.running", ["command": "git diff"])) { try await git.rangeFiles(root, oldest.hash, newest.hash) }
    let range = "\(oldest.shortHash)..\(newest.shortHash)"
    await app.showModal { (close: @escaping (()) -> Void) in
      CommitFilesView(
        app,
        close,
        tr("log_view.heading_count", ["title": range, "count": last - first + 1]),
        files,
        { try await git.rangeDiff(root, oldest.hash, newest.hash) },
        range
      )
    }
  }

  override var empty: String { tr("log_view.empty.commits") }

  override func drawRow(_ screen: Screen, _ y: Int, _ w: Int, _ index: Int, _ style: Style) {
    let c = commits[index]
    // 先頭の2文字はマーク（*）と空白。
    var x = 2
    x += screen.text(x, y, c.shortHash, style.copyWith(fg: Palette.orange)) + 2
    x += screen.text(x, y, c.date, style.copyWith(fg: Palette.muted)) + 2
    x += screen.text(x, y, truncate(c.author, 14), style.copyWith(fg: Palette.cyan)) + 2
    screen.text(x, y, truncate(c.subject, max(0, w - x - 1)), style)
  }

  override func open(_ index: Int) async throws {
    let (app, git, root) = (app, git, root)
    let commit = commits[index]
    let files = try await app.withProgress(tr("log_view.running", ["command": "git show"])) { try await git.commitFiles(root, commit.hash) }
    await app.showModal { (close: @escaping (()) -> Void) in
      CommitFilesView(
        app,
        close,
        "\(commit.shortHash)  \(commit.subject)",
        files,
        { try await git.commitDiff(root, commit.hash) },
        commit.shortHash
      )
    }
  }
}

/// タグの一覧（作った日の新しい順）と、それが指すコミット。Enter で、そのコミットで変わったファイルの一覧を出す。
final class TagView: LogListView {
  init(_ app: App, _ close: @escaping (()) -> Void, _ git: Git, _ root: String, _ tags: [GitTag]) {
    self.git = git
    self.root = root
    self.tags = tags
    super.init(app, close, "git tag")
  }

  let git: Git
  let root: String
  var tags: [GitTag]

  /// タグ名の列の幅。長すぎるものは切る。
  private var nameWidth: Int { min(24, tags.map { textWidth($0.name) }.max() ?? 0) }

  override var heading: String { tr("log_view.heading_tags", ["title": title, "count": tags.count]) }

  override var length: Int { tags.count }

  override var markable: Bool { true }

  override var deletable: Bool { true }

  /// 確かめてから、手元のタグを消す（git tag -d）。消したら一覧を読み直す。
  override func delete(_ indices: [Int]) async throws {
    let names = indices.map { tags[$0].name }
    // 消すタグを、一覧の順に1行ずつ並べる。
    if !(await app.confirm(
      "git tag -d",
      ([tr("log_view.delete_tags.message")] + names).joined(separator: "\n"),
      yes: tr("log_view.delete_tags.yes")
    )) {
      return
    }
    let (git, root) = (git, root)
    tags = try await app.withProgress(tr("log_view.running", ["command": "git tag -d"])) {
      try await git.deleteTags(root, names)
      return try await git.tags(root)
    }
    marks.removeAll()
  }

  /// 一覧は新しい順なので、[first] が一番新しく、[last] が一番古い。その間のコミット（古いほうのタグのコミットは含めない）を出す。
  override func openRange(_ first: Int, _ last: Int) async throws {
    let (app, git, root) = (app, git, root)
    let newest = tags[first]
    let oldest = tags[last]
    let commits = try await app.withProgress(tr("log_view.running", ["command": "git log"])) {
      try await git.rangeLog(root, oldest.commit.hash, newest.commit.hash)
    }
    await app.showModal { (close: @escaping (()) -> Void) in
      RangeLogView(app, close, "\(oldest.name)..\(newest.name)", commits)
    }
  }

  override var empty: String { tr("log_view.empty.tags") }

  override func drawRow(_ screen: Screen, _ y: Int, _ w: Int, _ index: Int, _ style: Style) {
    let tag = tags[index]
    let c = tag.commit
    // 先頭の2文字は、ほかの一覧のマーク（*）と空白に揃える。
    var x = 2
    x += screen.text(x, y, padRight(truncate(tag.name, nameWidth), nameWidth), style.copyWith(fg: Palette.lime, bold: true)) + 2
    x += screen.text(x, y, c.shortHash, style.copyWith(fg: Palette.orange)) + 2
    x += screen.text(x, y, c.date, style.copyWith(fg: Palette.muted)) + 2
    x += screen.text(x, y, truncate(c.author, 14), style.copyWith(fg: Palette.cyan)) + 2
    screen.text(x, y, truncate(c.subject, max(0, w - x - 1)), style)
  }

  override func open(_ index: Int) async throws {
    let (app, git, root) = (app, git, root)
    let tag = tags[index]
    let commit = tag.commit
    let files = try await app.withProgress(tr("log_view.running", ["command": "git show"])) { try await git.commitFiles(root, commit.hash) }
    await app.showModal { (close: @escaping (()) -> Void) in
      CommitFilesView(
        app,
        close,
        "\(tag.name)  \(commit.shortHash)  \(commit.subject)",
        files,
        { try await git.commitDiff(root, commit.hash) },
        commit.shortHash
      )
    }
  }
}

/// 2つのタグの間のコミットの一覧（リリースノート）。見るだけで、マークも Enter もない。
final class RangeLogView: LogListView {
  init(_ app: App, _ close: @escaping (()) -> Void, _ title: String, _ commits: [GitCommit]) {
    self.commits = commits
    super.init(app, close, title)
  }

  let commits: [GitCommit]

  override var heading: String { tr("log_view.heading_count", ["title": title, "count": commits.count]) }

  override var length: Int { commits.count }

  override var openable: Bool { false }

  override var empty: String { tr("log_view.empty.range_commits") }

  override func drawRow(_ screen: Screen, _ y: Int, _ w: Int, _ index: Int, _ style: Style) {
    let c = commits[index]
    // 先頭の2文字は、ほかの一覧のマーク（*）と空白に揃える。
    var x = 2
    x += screen.text(x, y, c.shortHash, style.copyWith(fg: Palette.orange)) + 2
    x += screen.text(x, y, c.date, style.copyWith(fg: Palette.muted)) + 2
    x += screen.text(x, y, truncate(c.author, 14), style.copyWith(fg: Palette.cyan)) + 2
    screen.text(x, y, truncate(c.subject, max(0, w - x - 1)), style)
  }
}

/// 1つのファイルが変わったコミットの一覧（名前の変更もたどる）。Enter で、そのコミットでのそのファイルの差分を出す。
/// 名前が変わったコミットには「旧名 → 新名」を添える。
final class FileLogView: LogListView {
  init(_ app: App, _ close: @escaping (()) -> Void, _ git: Git, _ root: String, _ dir: String, _ path: String, _ commits: [FileCommit]) {
    self.git = git
    self.root = root
    self.dir = dir
    self.path = path
    self.commits = commits
    super.init(app, close, "git log  \(path)")
  }

  let git: Git
  let root: String

  /// [path] の基準のフォルダー。
  let dir: String
  let path: String
  var commits: [FileCommit]

  override var heading: String { tr("log_view.heading_count", ["title": title, "count": commits.count]) }

  override var length: Int { commits.count }

  override var editable: Bool { true }

  override func edit(_ index: Int) async throws {
    if try await editCommit(app, git, root, commits[index].commit.hash) {
      commits = try await app.withProgress(tr("log_view.running", ["command": "git log"])) { try await git.fileLog(dir, path) }
      marks.removeAll()
    }
  }

  override var markable: Bool { true }

  /// 一覧は新しい順なので、[first] が一番新しく、[last] が一番古い。差分の両端では名前が違うことがあるので、両方を渡す。
  override func openRange(_ first: Int, _ last: Int) async throws {
    let newest = commits[first]
    let oldest = commits[last]
    var paths = [oldest.file.from ?? oldest.file.path]
    if !same(newest.file.path, paths[0]) {
      paths.append(newest.file.path)
    }
    let diff = try await app.withProgress(tr("log_view.running", ["command": "git diff"])) {
      try await git.rangeDiff(root, oldest.commit.hash, newest.commit.hash, paths: paths)
    }
    if diff.isEmpty {
      app.showStatus(tr("log_view.no_diff"))
      return
    }
    let range = "\(oldest.commit.shortHash)..\(newest.commit.shortHash)"
    await app.showModal { (close: @escaping (()) -> Void) in DiffView(diff.map { (file: $0, section: range) }, close) }
  }

  override var empty: String { tr("log_view.empty.file_commits") }

  override func drawRow(_ screen: Screen, _ y: Int, _ w: Int, _ index: Int, _ style: Style) {
    let commit = commits[index].commit
    let file = commits[index].file
    // 先頭の2文字はマーク（*）と空白。
    var x = 2
    x += screen.text(x, y, commit.shortHash, style.copyWith(fg: Palette.orange)) + 2
    x += screen.text(x, y, commit.date, style.copyWith(fg: Palette.muted)) + 2
    x += screen.text(x, y, truncate(commit.author, 14), style.copyWith(fg: Palette.cyan)) + 2
    if let from = file.from, file.status == "R" {
      x += screen.text(x, y, truncate("\(from) → \(file.path)", max(0, w - x - 1)), style.copyWith(fg: Palette.cyan)) + 2
    }
    screen.text(x, y, truncate(commit.subject, max(0, w - x - 1)), style)
  }

  override func open(_ index: Int) async throws {
    let commit = commits[index].commit
    let file = commits[index].file
    let diff = try await app.withProgress(tr("log_view.running", ["command": "git show"])) { try await git.fileDiff(root, commit.hash, file) }
    if diff.isEmpty {
      app.showStatus(tr("log_view.no_diff"))
      return
    }
    await app.showModal { (close: @escaping (()) -> Void) in
      DiffView(diff.map { (file: $0, section: commit.shortHash) }, close)
    }
  }
}

/// コミット（またはコミットの範囲）で変わったファイルの一覧。Enter で、そのファイルの差分を出す。
final class CommitFilesView: LogListView {
  init(
    _ app: App,
    _ close: @escaping (()) -> Void,
    _ title: String,
    _ files: [CommitFile],
    _ loadDiff: @escaping () async throws -> [DiffFile],
    _ section: String
  ) {
    self.files = files
    self.loadDiff = loadDiff
    self.section = section
    super.init(app, close, title)
  }

  let files: [CommitFile]

  /// 差分を読む。
  let loadDiff: () async throws -> [DiffFile]

  /// 差分の画面の見出しに添えるもの（コミットのハッシュなど）。
  let section: String

  /// 差分。初めて Enter を押したときに読む。
  private var diff: [DiffFile]?

  override var length: Int { files.count }

  override var empty: String { tr("log_view.empty.files") }

  override func drawRow(_ screen: Screen, _ y: Int, _ w: Int, _ index: Int, _ style: Style) {
    let file = files[index]
    let color =
      switch file.status {
      case "A": Palette.green
      case "D": Palette.red
      case "R", "C": Palette.cyan
      default: Palette.orange
      }
    screen.text(2, y, file.status, style.copyWith(fg: color, bold: true))
    let name = file.from == nil ? file.path : "\(file.from!) -> \(file.path)"
    screen.text(5, y, truncate(name, max(0, w - 6)), style)
  }

  override func open(_ index: Int) async throws {
    let diff: [DiffFile]
    if let loaded = self.diff {
      diff = loaded
    } else {
      diff = try await app.withProgress(tr("log_view.running", ["command": "git diff"]), loadDiff)
    }
    self.diff = diff
    if diff.isEmpty {
      app.showStatus(tr("log_view.no_diff"))
      return
    }
    // 選んだファイルのページから開く（← → で同じコミットのほかのファイルへ）。
    let path = files[index].path
    let page = diff.firstIndex { same($0.path, path) } ?? -1
    let section = section
    await app.showModal { (close: @escaping (()) -> Void) in
      DiffView(diff.map { (file: $0, section: section) }, close, page: max(0, page))
    }
  }
}
