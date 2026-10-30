import Foundation

/// 一覧の1行。
final class Entry {
  init(
    name: String,
    isDir: Bool,
    size: Int? = nil,
    modified: Date? = nil,
    executable: Bool = false,
    mode: Int? = nil,
    isLink: Bool = false,
    data: Any
  ) {
    self.name = name
    self.isDir = isDir
    self.size = size
    self.modified = modified
    self.executable = executable
    self.mode = mode
    self.isLink = isLink
    self.data = data
  }

  let name: String
  let isDir: Bool

  /// ローカルの項目のパーミッション（setuid などを含む下位12ビット）。
  let mode: Int?

  /// 実行権限のあるローカルのファイル。
  let executable: Bool

  /// シンボリックリンク（ローカル・SSH）。フォルダーへのリンクは [isDir] も true。
  let isLink: Bool
  let size: Int?
  let modified: Date?

  /// LocalSource（ローカル・Google Drive・iCloud Drive）、圧縮ファイルの中の項目、SSH の項目など。
  let data: Any

  /// 一覧の先頭に置く親フォルダー（..）。
  static let parent = Entry(name: "..", isDir: true, data: ())

  var isParent: Bool { self === Entry.parent }
}

/// ローカルのファイルの所有者・グループ・パーミッション（ls -l の形）。
struct Ownership {
  init(_ owner: String, _ group: String, _ permissions: String) {
    self.owner = owner
    self.group = group
    self.permissions = permissions
  }

  let owner: String
  let group: String
  let permissions: String
}

/// マークした項目。フォルダーを移っても残る。
struct Mark {
  init(_ entry: Entry, _ parent: String) {
    self.entry = entry
    self.parent = parent
  }

  let entry: Entry

  /// マークしたときに開いていたフォルダー（ローカル・Google Drive・iCloud Drive はパス）。
  let parent: String
}

/// Dart の String.compareTo と同じく、UTF-16 の符号単位で比べる。
nonisolated func compareCodeUnits(_ a: String, _ b: String) -> Int {
  var ia = a.utf16.makeIterator()
  var ib = b.utf16.makeIterator()
  while true {
    switch (ia.next(), ib.next()) {
    case (nil, nil): return 0
    case (nil, _): return -1
    case (_, nil): return 1
    case let (x?, y?):
      if x != y {
        return x < y ? -1 : 1
      }
    }
  }
}

/// フォルダーを先に、名前を大文字小文字を区別せずに並べる。
func compareEntries(_ a: Entry, _ b: Entry) -> Int {
  if a.isDir != b.isDir {
    return a.isDir ? -1 : 1
  }
  return compareCodeUnits(a.name.lowercased(), b.name.lowercased())
}

/// 順序付きの辞書（Dart の Map は追加した順を保つ）。
struct OrderedMap<K: Hashable, V> {
  private(set) var keys: [K] = []
  private var storage: [K: V] = [:]

  var isEmpty: Bool { keys.isEmpty }
  var count: Int { keys.count }
  var values: [V] { keys.map { storage[$0]! } }

  subscript(key: K) -> V? {
    get { storage[key] }
    set {
      if let newValue {
        if storage.updateValue(newValue, forKey: key) == nil {
          keys.append(key)
        }
      } else {
        removeValue(forKey: key)
      }
    }
  }

  func containsKey(_ key: K) -> Bool { storage[key] != nil }

  @discardableResult
  mutating func removeValue(forKey key: K) -> V? {
    guard let value = storage.removeValue(forKey: key) else { return nil }
    keys.removeAll { $0 == key }
    return value
  }

  mutating func removeAll(where test: (K, V) -> Bool) {
    keys.removeAll { key in
      if test(key, storage[key]!) {
        storage.removeValue(forKey: key)
        return true
      }
      return false
    }
  }

  mutating func clear() {
    keys.removeAll()
    storage.removeAll()
  }
}

/// 左右の画面の共通部分。カーソル・マーク・読み込み。継承して使う（Dart の abstract class Pane）。
class Pane {
  init(_ app: App) {
    self.app = app
  }

  let app: App
  var entries: [Entry] = []
  var cursor = 0
  var scroll = 0

  /// マークした項目。キーは [keyOf]（フォルダーをまたいでも一意）。マークした順。
  var marks = OrderedMap<String, Mark>()
  var loading = false
  var error: (any Error)?
  private var generation = 0

  /// 開いているドライブの容量。取得前・取得できないときは nil。
  var usage: DiskUsage?

  var title: String { fatalError("title") }
  var location: String { fatalError("location") }
  var accent: Rgb { fatalError("accent") }

  /// 選んでいる窓のカーソルの行の地の色。
  var selection: Rgb { colors.selection ?? colors.selected }

  /// この窓のタブの見た目（設定ファイルの appearance）。
  var themeKey: ThemeKey { .defaults }

  /// このタブの配色（描いている範囲によらない。上の帯でもタブの色を使うため）。
  var colors: ThemeColors { Appearance.current.theme(themeKey).colors }

  /// 上の帯に出す容量の項目（Total・Used・Free のうち）。
  var usageLabels: [String] { ["Total", "Used", "Free"] }

  /// 上の帯に、容量（Total・Used・Free）の代わりに出す文。容量を出すなら nil。
  var headerText: String? { nil }

  /// 一覧に使える行数。前回描いたときの値（PgUp・PgDn の幅に使う）。
  private(set) var visibleRows = 0

  /// 一覧の代わりに表示する案内（iCloudのログイン前など）。
  var placeholder: [String]? { nil }

  /// 読み直している間も、前の一覧を出したままにするか（読み込み中の表示で一覧を消さない）。
  var keepsEntriesWhileLoading: Bool { false }

  func fetch() async throws -> [Entry] { fatalError("fetch") }

  /// 親フォルダーがあるか（.. を出すか）。
  var canGoUp: Bool { fatalError("canGoUp") }

  /// 容量。対応していなければ nil。
  func fetchUsage() async throws -> DiskUsage? { nil }

  /// 項目の所有者など。ローカル以外は nil。
  func ownershipOf(_ entry: Entry) -> Ownership? { nil }

  var current: Entry? { entries.isEmpty ? nil : entries[min(max(cursor, 0), entries.count - 1)] }

  /// 開いているフォルダー（[Mark.parent] と同じ形）。
  var folderKey: String { fatalError("folderKey") }

  /// 項目を一意に表すキー。
  func keyOf(_ entry: Entry) -> String { "\(folderKey)/\(entry.name)" }

  func isMarked(_ entry: Entry) -> Bool { !entry.isParent && marks.containsKey(keyOf(entry)) }

  /// 操作の対象。マークが1つ以上あればマークだけ（ほかのフォルダーの分も含む。マークした順）、なければカーソルの項目。
  /// 親フォルダー（..）は [includeParent] のときだけ対象にする。
  func targetsFor(includeParent: Bool = false) -> [Mark] {
    !marks.isEmpty ? marks.values : cursorTargets(includeParent: includeParent)
  }

  /// カーソルの項目だけの対象（マークは見ない）。親フォルダー（..）は [includeParent] のときだけ対象にする。
  func cursorTargets(includeParent: Bool = false) -> [Mark] {
    guard let entry = current, !entry.isParent || includeParent else {
      return []
    }
    return [Mark(entry, folderKey)]
  }

  /// [targetsFor] の、親フォルダーを含めないもの。
  var targetMarks: [Mark] { targetsFor() }

  /// 開いているフォルダーの外にあるマークの数。
  var marksElsewhere: Int { marks.values.filter { $0.parent != folderKey }.count }

  /// 読み直す。[focus] の名前があればカーソルを合わせる。
  func load(focus: String? = nil) async {
    generation += 1
    let generation = generation
    let keep = focus ?? current?.name
    loading = true
    error = nil
    app.requestRender()
    // 容量は一覧とは別に取り、一覧の表示を待たせない。
    Task {
      let value = try? await fetchUsage()
      if generation == self.generation {
        usage = value
        app.requestRender()
      }
    }
    do {
      let list = try await fetch()
      if generation != self.generation {
        return
      }
      entries = (canGoUp ? [Entry.parent] : []) + list
      refreshMarks(list)
      let index = keep.flatMap { name in entries.firstIndex { $0.name == name } }
      cursor = index ?? min(max(cursor, 0), entries.isEmpty ? 0 : entries.count - 1)
      if !entries.isEmpty {
        cursor = nearestSelectable(cursor, 1)
      }
    } catch {
      if generation != self.generation {
        return
      }
      entries = []
      self.error = error
    }
    if generation == self.generation {
      loading = false
      app.requestRender()
    }
  }

  /// フォルダーを開く。
  func open(_ entry: Entry) async {}

  /// 親フォルダーへ。
  func up() async {}

  /// カーソルとスクロールを先頭に戻す（別のフォルダーを開くとき）。
  func resetCursor() {
    cursor = 0
    scroll = 0
  }

  /// カーソルが乗る項目か（git の窓の見出しなどは乗らない）。
  func selectable(_ entry: Entry) -> Bool { true }

  func move(_ delta: Int) {
    if entries.isEmpty {
      return
    }
    cursor = nearestSelectable(min(max(cursor + delta, 0), entries.count - 1), delta < 0 ? -1 : 1)
  }

  /// [from] から [step] の向きに、カーソルが乗る項目を探す。その向きになければ逆の向きに探す。どこにもなければ今の位置。
  private func nearestSelectable(_ from: Int, _ step: Int) -> Int {
    for s in [step, -step] {
      var i = from
      while i >= 0 && i < entries.count {
        if selectable(entries[i]) {
          return i
        }
        i += s
      }
    }
    return cursor
  }

  /// このフォルダーのマークを、読み直した項目に置き換える（パーミッションなどを新しくし、なくなった項目は外す）。
  private func refreshMarks(_ list: [Entry]) {
    var byKey: [String: Entry] = [:]
    for e in list {
      byKey[keyOf(e)] = e
    }
    let folder = folderKey
    marks.removeAll { key, mark in mark.parent == folder && byKey[key] == nil }
    for key in marks.keys {
      if let fresh = byKey[key] {
        marks[key] = Mark(fresh, folder)
      }
    }
  }

  /// マークできるか（圧縮ファイルの中は読むだけなのでできない）。
  var canMark: Bool { true }

  /// [entry] をマークできるか（Git の窓のブランチ名・見出しはできない）。
  func markable(_ entry: Entry) -> Bool { true }

  private func toggle(_ entry: Entry) {
    if entry.isParent || !canMark || !markable(entry) {
      return
    }
    let key = keyOf(entry)
    if marks.removeValue(forKey: key) == nil {
      marks[key] = Mark(entry, folderKey)
    }
  }

  func toggleMark() {
    if entries.isEmpty {
      return
    }
    toggle(entries[cursor])
    move(1)
  }

  /// 開いているフォルダーの中だけ反転する。
  func invertMarks() {
    for entry in entries {
      toggle(entry)
    }
  }

  // ---- 描画 ----

  /// ファイルの名前の色（フォルダー・隠しファイルなどを除く）。
  var fileColor: Rgb { Palette.text }

  /// 枠・場所・一覧を描く。[accentBorder] なら、選んでいなくても自分の色の枠にする。
  func draw(_ screen: Screen, _ x: Int, _ y: Int, _ w: Int, _ h: Int, focused: Bool, accentBorder: Bool) {
    let bg = Style()
    screen.box(
      x, y, w, h, bg.copyWith(fg: accentBorder ? accent : Palette.outline),
      title: title,
      titleStyle: bg.copyWith(fg: accent, bold: focused)
    )
    screen.text(x + 1, y + 1, truncateLeft(location, w - 2), bg.copyWith(fg: Palette.location))
    drawBody(screen, x + 1, y + 2, w - 2, h - 3, focused: focused)
  }

  /// 枠の中の一覧（[x]・[y] から幅 [width]・[rows] 行）。スクロール位置は右の枠の上に出す。
  func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ width: Int, _ rows: Int, focused: Bool) {
    visibleRows = rows
    let bg = Style()
    if let placeholder {
      // 案内は窓の幅で折り返す。
      let lines = placeholder.flatMap { wrap($0, width - 2) }
      for i in 0..<min(lines.count, max(rows, 0)) {
        screen.text(x + 1, y + i, lines[i], bg)
      }
      return
    }
    if loading && !(keepsEntriesWhileLoading && !entries.isEmpty) {
      screen.text(x + 1, y, tr("pane.loading"), bg.copyWith(fg: Palette.muted))
      return
    }
    if let error {
      let lines = wrap(tr("pane.load_failed", ["message": errorMessage(error)]), width - 2)
      for i in 0..<max(0, min(lines.count, rows - 2)) {
        screen.text(x + 1, y + i, lines[i], bg.copyWith(fg: Palette.error))
      }
      screen.text(x + 1, y + min(lines.count, rows - 2) + 1, tr("pane.reload_hint"), bg.copyWith(fg: Palette.muted))
      return
    }
    if entries.isEmpty {
      screen.text(x + 1, y, tr("pane.empty_folder"), bg.copyWith(fg: Palette.muted))
      return
    }

    scroll = fitScroll(cursor: cursor, scroll: scroll, length: entries.count, rows: rows)

    var i = 0
    while i < rows && scroll + i < entries.count {
      let index = scroll + i
      let entry = entries[index]
      // 選んでいない窓のカーソルの行は、同じ色を8割透かす。
      let style = index == cursor ? bg.copyWith(bg: focused ? selection : selection.withOpacity(0.2)) : bg
      screen.fill(x, y + i, width, 1, style)
      drawRow(screen, entry, x, y + i, width, style, marked: isMarked(entry))
      i += 1
    }
    if entries.count == 1 && entries[0].isParent && rows > 1 {
      screen.text(x + 2, y + 1, tr("pane.empty_folder"), bg.copyWith(fg: Palette.muted))
    }
    // スクロール位置。
    if entries.count > rows {
      let thumb = Int((Double(scroll) / Double(entries.count - rows) * Double(rows - 1)).rounded())
      screen.text(x + width, y + thumb, "┃", bg.copyWith(fg: accent))
    }
  }

  /// 一覧の1行。列はマーク(1) 名前 サイズ(9) 日時(14)。日時は幅があるときだけ出す。
  func drawRow(_ screen: Screen, _ entry: Entry, _ x: Int, _ y: Int, _ width: Int, _ style: Style, marked: Bool) {
    let showDate = width >= 50
    let nameWidth = width - 2 - 1 - 9 - (showDate ? 15 : 0) - 1
    // マーク > シンボリックリンク > 実行ファイル（赤）> 隠しファイル（水色）> フォルダー の順に優先する。
    let nameColor =
      marked
      ? Palette.marked
      : entry.isLink
        ? Palette.symlink
        : entry.executable
        ? Palette.executable
        : !entry.isParent && entry.name.hasPrefix(".")
          ? Palette.hidden
          : entry.isDir
            ? Palette.directory
            : fileColor
    screen.text(x, y, marked ? "*" : " ", style.copyWith(fg: Palette.marked, bold: true))
    screen.text(
      x + 2, y, truncate(entry.isDir && !entry.isParent ? "\(entry.name)/" : entry.name, nameWidth),
      style.copyWith(fg: nameColor, bold: marked)
    )
    let size =
      entry.isParent
      ? "<UP>"
      : entry.isDir
        ? "<DIR>"
        : (entry.size.map(formatBytes) ?? "")
    var col = x + 2 + nameWidth + 1
    screen.text(col, y, padLeft(size, 9), style.copyWith(fg: Palette.muted))
    col += 10
    if showDate, let modified = entry.modified {
      screen.text(col, y, formatDate(modified), style.copyWith(fg: Palette.muted))
    }
  }

  // ---- 操作の前提（操作そのものは Command/ のコマンドが行う） ----

  /// 読み込みが済み、一覧を出している。
  var ready: Bool { !loading && error == nil && placeholder == nil }

  /// 読むだけの場所（圧縮ファイルの中など）を開いている。
  var readOnly: Bool { false }

  /// [readOnly] なら、使えないことを伝えて false を返す。
  func checkWritable() async -> Bool { true }

  /// 読み直す（L）。
  func reload() async { await load() }

  // ---- このタブが持つコマンド ----

  /// このタブで使える操作と、そのコマンド。ここにない操作のキーは何もしない。
  var commands: [Operation: Command] { [:] }

  /// 右に出しているときの G・F12 の転送。右に出すタブだけが持つ。
  var transferCommand: Command? { nil }

  /// コマンドではないキー（カーソル移動・マーク・プレビューなど）を使えるか。
  /// [id] はキーの名前、文字は「char:小文字」。
  func allowsKey(_ id: String) -> Bool { true }

  /// [targets] を、P で貼り付ける対象にする（C・M）。対応しなければ nil。
  func makeClip(_ targets: [Mark], move: Bool) -> Clip? { nil }

  /// C・M（F2・F3）で選べるか（[makeClip] を持ち、読むだけの場所でない）。
  var canClip: Bool { false }
}

/// パスで扱える窓（ローカルと SSH の接続先）の共通部分。ファイルの操作は各タブのコマンドが行う。
class PathPane: Pane {
  /// パスの書き方。
  var context: PathContext { fatalError("context") }

  /// 開いているフォルダーのパス。
  var dirPath: String { fatalError("dirPath") }

  var showHidden = false

  /// [path] のフォルダーへ移り、[focus] の名前にカーソルを合わせる。
  func goToDir(_ path: String, focus: String? = nil) async {}

  /// [path] のファイルをエディタで開く。
  func editFile(_ path: String) async {}

  func pathOf(_ entry: Entry) -> String { context.join(dirPath, entry.name) }

  /// マークした項目のフルパス。
  func pathOfMark(_ mark: Mark) -> String { context.join(mark.parent, mark.entry.name) }
}
