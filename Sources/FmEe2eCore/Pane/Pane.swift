import AppKit

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
  init(_ owner: String, _ group: String, _ permissions: String, linkTarget: String? = nil) {
    self.owner = owner
    self.group = group
    self.permissions = permissions
    self.linkTarget = linkTarget
  }

  let owner: String
  let group: String
  let permissions: String

  /// シンボリックリンクなら、指している先のパス。上の帯の Mode の右に出す。
  let linkTarget: String?
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

/// UTF-16 の符号単位で比べる。
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

/// 順序付きの辞書（追加した順を保つ）。
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

/// 左右の画面の共通部分。カーソル・マーク・読み込み。継承して使う。
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

  /// 上の帯の2行（容量と所有者の行）の代わりに出す、名前と値の組。nil ならいつもの容量と所有者を出す。
  var headerFields: [[(String, String)]]? { nil }

  /// カーソルの項目。タイル表示では、タイルに出していない項目（タイルが1つもないとき）は nil。
  var current: Entry? {
    if entries.isEmpty {
      return nil
    }
    let entry = entries[min(max(cursor, 0), entries.count - 1)]
    return tiled && !tileable(entry) ? nil : entry
  }

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
    return [markFor(entry)]
  }

  /// [entry] をマークしたときのもの。ふつうは開いているフォルダーの項目（検索の結果は、そのファイルのあるフォルダー）。
  func markFor(_ entry: Entry) -> Mark { Mark(entry, folderKey) }

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
      if tiled {
        snapToTile()
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
    if tiled {
      let tiles = tileIndices
      if !tiles.isEmpty {
        let position = tiles.firstIndex(of: cursor) ?? 0
        cursor = tiles[min(max(position + delta, 0), tiles.count - 1)]
      }
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
        marks[key] = markFor(fresh)
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
      marks[key] = markFor(entry)
    }
  }

  func toggleMark() {
    guard let entry = current else {
      return
    }
    toggle(entry)
    move(1)
  }

  /// 開いているフォルダーの中だけ反転する。タイル表示では、タイルに出している項目だけ。
  func invertMarks() {
    for entry in entries where !tiled || tileable(entry) {
      toggle(entry)
    }
  }

  // ---- タイル表示（Ctrl+T） ----

  /// Ctrl+T でタイル表示にした。
  private var tileOn = false

  /// 開いているフォルダーの画像・動画だけを、サムネイルのタイルで並べている（SSH の接続前などは、Ctrl+T を押していても一覧）。
  var tiled: Bool { tileOn && canTile }

  /// タイル表示にできるか（ファイルを一覧している）。
  var canTile: Bool { false }

  /// タイルに出す項目か（画像・動画のファイル）。
  func tileable(_ entry: Entry) -> Bool {
    canTile && !entry.isDir && !entry.isParent && previewKindOf(entry.name) != nil
  }

  /// タイルに出す項目の、[entries] での位置。
  var tileIndices: [Int] { entries.indices.filter { tileable(entries[$0]) } }

  /// 1行に並べるタイルの数（前回描いたときの値。↑↓ で1行分動かすのに使う）。
  private(set) var tileColumns = 1

  /// タイルの行のスクロール位置。
  private var tileScroll = 0

  private lazy var tileImages = TileImages(app)

  /// タイル表示と一覧を切り替える。タイル表示にするときは、カーソルをタイルの項目に合わせる。マークはそのまま。
  func toggleTiles() {
    tileOn.toggle()
    if tiled {
      snapToTile()
    }
  }

  /// カーソルがタイルの項目になければ、後ろ（なければ前）の一番近いタイルの項目に合わせる。
  private func snapToTile() {
    guard cursor >= 0, cursor < entries.count, !tileable(entries[cursor]) else {
      return
    }
    let next = entries.indices.first { $0 > cursor && tileable(entries[$0]) } ?? entries.indices.last { $0 < cursor && tileable(entries[$0]) }
    if let next {
      cursor = next
    }
  }

  /// タイル表示のサムネイル。作れなければ nil。
  func thumbnail(_ entry: Entry, _ kind: PreviewKind) async -> NSImage? { nil }

  /// サムネイルを作らずに、タイルに代わりに出す文（大きすぎる動画など）。作るなら nil。
  func thumbnailNote(_ entry: Entry, _ kind: PreviewKind) -> String? { nil }

  /// タイルの大きさ（桁・行）。名前の1行と、画像の行。右と下の1つずつは、タイルの間を空ける分。
  private static let tileWidth = 22
  private static let tileHeight = 11

  /// 枠の中に、画像・動画のタイルを並べる（[x]・[y] から幅 [width]・[rows] 行）。各タイルの左上はマークのチェックボックス。
  private func drawTiles(_ screen: Screen, _ x: Int, _ y: Int, _ width: Int, _ rows: Int, focused: Bool) {
    let bg = Style()
    let tiles = tileIndices
    if tiles.isEmpty {
      visibleRows = rows
      screen.text(x + 1, y, tr("tiles.empty"), bg.copyWith(fg: Palette.muted))
      return
    }
    let columns = max(1, width / Self.tileWidth)
    let tileW = width / columns
    let tileH = max(3, min(rows, Self.tileHeight))
    let visibleTileRows = max(1, rows / tileH)
    tileColumns = columns
    visibleRows = columns * visibleTileRows
    let rowCount = (tiles.count + columns - 1) / columns
    let cursorRow = (tiles.firstIndex(of: cursor) ?? 0) / columns
    tileScroll = fitScroll(cursor: cursorRow, scroll: tileScroll, length: rowCount, rows: visibleTileRows)
    var wanted: [(id: String, make: () async -> NSImage?)] = []
    // 項目を描いたタイルの位置（ドラッグで渡すパスを引くため）。
    var placed: [(x: Int, y: Int, entry: Entry)] = []
    for row in 0..<visibleTileRows {
      for column in 0..<columns {
        let index = (tileScroll + row) * columns + column
        guard index < tiles.count else {
          break
        }
        let entry = entries[tiles[index]]
        let kind = previewKindOf(entry.name)!
        let tx = x + column * tileW
        let ty = y + row * tileH
        placed.append((tx, ty, entry))
        // 選んでいない窓のカーソルのタイルは、同じ色を8割透かす。
        let style = tiles[index] == cursor ? bg.copyWith(bg: focused ? selection : selection.withOpacity(0.2)) : bg
        screen.fill(tx, ty, tileW - 1, tileH - 1, style)
        let marked = isMarked(entry)
        screen.text(tx, ty, marked ? "[x]" : "[ ]", style.copyWith(fg: Palette.marked, bold: true))
        screen.text(tx + 4, ty, truncate(entry.name, max(0, tileW - 5)), style.copyWith(fg: marked ? Palette.marked : fileColor, bold: marked))
        // 画像は、名前の下から、タイルの間の1行・1桁の手前まで。
        let (ix, iy, iw, ih) = (tx + 1, ty + 1, max(1, tileW - 3), max(1, tileH - 2))
        let muted = style.copyWith(fg: Palette.muted)
        if let note = thumbnailNote(entry, kind) {
          screen.text(ix, iy, truncate(note, iw), muted)
          continue
        }
        let id = "\(keyOf(entry))|\(entry.size.map(String.init) ?? "null")|\(entry.modified.map { "\($0.timeIntervalSince1970)" } ?? "null")"
        switch tileImages.image(id) {
        case .some(.some(let image)):
          // 画像か動画かを、右下の印で見分けられるようにする。
          screen.images.append(ScreenImage(ix, iy, iw, ih, image, badge: kind == .video ? "🎬" : "🪟"))
        case .some(.none):
          screen.text(ix, iy, truncate(tr("preview_overlay.unavailable"), iw), muted)
        case .none:
          screen.text(ix, iy, truncate(tr("preview_overlay.loading"), iw), muted)
          wanted.append((id, { [weak self] in await self?.thumbnail(entry, kind) ?? nil }))
        }
      }
    }
    tileImages.request(wanted)
    if dragsFiles {
      screen.filesAt = { [weak self] cx, cy in
        guard let self, let tile = placed.first(where: { cx >= $0.x && cx < $0.x + tileW && cy >= $0.y && cy < $0.y + tileH }) else {
          return nil
        }
        return dragPaths(tile.entry)
      }
    }
    // スクロール位置。
    if rowCount > visibleTileRows {
      let thumb = Int((Double(tileScroll) / Double(rowCount - visibleTileRows) * Double(rows - 1)).rounded())
      screen.text(x + width, y + thumb, "┃", bg.copyWith(fg: accent))
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
      // 案内は窓の幅で折り返す。URL はクリックで開けるリンクにする（折り返しても1本の URL として開く）。
      var row = 0
      for paragraph in placeholder.flatMap({ $0.components(separatedBy: "\n") }) {
        let links = TerminalModal.urls(in: paragraph)
        var offset = 0
        for line in wrap(paragraph, width - 2) {
          if row >= rows {
            return
          }
          var col = x + 1
          for cell in cells(line) {
            let link = links.first { $0.range.contains(offset) }?.url
            col += screen.text(col, y + row, cell, link == nil ? bg : bg.copyWith(underline: true, link: link))
            offset += cell.utf16.count
          }
          row += 1
        }
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
    if tiled {
      drawTiles(screen, x, y, width, rows, focused: focused)
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
    if dragsFiles {
      let first = scroll
      screen.filesAt = { [weak self] cx, cy in
        guard let self, cx >= x, cx < x + width, cy >= y, cy < y + rows, first + cy - y < entries.count else {
          return nil
        }
        return dragPaths(entries[first + cy - y])
      }
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

  /// この画面だけで意味を変えるキー。
  var keyOperations: [String: Operation] { [:] }

  /// タブ固有のファンクションキー。nil なら共通の並びを使う。
  var functionKeyLayout: [(String, String)?]? { nil }

  /// 右に出しているときの G・F12 の転送。右に出すタブだけが持つ。
  var transferCommand: Command? { nil }

  /// Esc で閉じるもの（検索の結果など）を出していれば、その Esc の説明。なければ nil。
  var escapeLabel: String? { nil }

  /// [escapeLabel] のものを閉じて、元の一覧に戻る。
  func closeByEscape() async {}

  /// コマンドではないキー（カーソル移動・マーク・プレビューなど）を使えるか。
  /// [id] はキーの名前、文字は「char:小文字」。
  func allowsKey(_ id: String) -> Bool { true }

  /// [targets] を、P で貼り付ける対象にする（C・M）。対応しなければ nil。
  func makeClip(_ targets: [Mark], move: Bool) -> Clip? { nil }

  /// C・M（F2・F3）で選べるか（[makeClip] を持ち、読むだけの場所でない）。
  var canClip: Bool { false }

  /// 一覧の行を CapsLock 中のドラッグでほかのアプリに渡せ、ほかのアプリからのドロップを受け取るか。
  var dragsFiles: Bool { false }

  /// [entry] の行を掴んだときに渡すパス。マークした行ならマークした全件、そうでなければその行だけ。渡せなければ nil。
  func dragPaths(_ entry: Entry) -> [String]? { nil }
}

/// パスで扱える窓（ローカルと SSH の接続先）の共通部分。ファイルの操作は各タブのコマンドが行う。
class PathPane: Pane {
  /// パスの書き方。
  var context: PathContext { fatalError("context") }

  /// 開いているフォルダーのパス。
  var dirPath: String { fatalError("dirPath") }

  var showHidden = false

  override var canTile: Bool { true }

  /// [path] のフォルダーへ移り、[focus] の名前にカーソルを合わせる。
  func goToDir(_ path: String, focus: String? = nil) async {}

  /// [path] のファイルをエディタで開く。
  func editFile(_ path: String) async {}

  func pathOf(_ entry: Entry) -> String {
    if found != nil, let path = foundPaths[ObjectIdentifier(entry)] {
      return path
    }
    return context.join(dirPath, entry.name)
  }

  /// マークした項目のフルパス。
  func pathOfMark(_ mark: Mark) -> String { context.join(mark.parent, mark.entry.name) }

  // ---- 検索の結果（F・F9） ----
  // 一覧の代わりに、窓いっぱいに出す。タブごとの継承クラスは、一覧の場所・使えるキーなどを [found] のときこの共通部分に任せる。

  /// 一覧の代わりに出している検索の結果。
  final class Found {
    init(_ query: FindQuery, _ items: [FoundItem], focus: String?) {
      self.query = query
      self.items = items
      paths = items.map(\.path)
      self.focus = focus
    }

    let query: FindQuery

    /// 探したときに読んだ結果。最初の読み込みで使い、そのあとは [refind] で読み直す。
    var items: [FoundItem]?
    let paths: [String]

    /// 閉じたときにカーソルを戻す名前。
    let focus: String?
  }

  private(set) var found: Found?

  /// 結果の一覧の項目ごとのフルパス（項目の名前はファイルの名前だけなので）。
  private var foundPaths: [ObjectIdentifier: String] = [:]

  /// 検索の結果を、窓いっぱいの一覧に出す。中身で探したときは、ファイルの下に合った行と前後の行を出す。
  func showFound(_ query: FindQuery, _ items: [FoundItem]) async {
    found = Found(query, items, focus: current?.name)
    resetCursor()
    await load()
  }

  /// 検索の結果を出すのをやめる（読み直しはしない）。
  func clearFound() {
    found = nil
    foundPaths = [:]
  }

  /// 結果の一覧を読み直す（エディタで書き換えたあとなど）。
  func refind(_ found: Found) async throws -> [FoundItem] { [] }

  /// 結果のファイルの行の [Entry.data]（ローカルは LocalFile、接続先は RemoteEntry）。
  func foundData(_ item: FoundItem) -> Any { fatalError("foundData") }

  /// [found] のときの [fetch]。ファイルの行の下に、合った行・前後の行を置き、中身で探したときはファイルごとに1行空ける。
  func fetchFound() async throws -> [Entry] {
    guard let found else {
      return []
    }
    let items: [FoundItem]
    if let first = found.items {
      items = first
      found.items = nil
    } else {
      items = try await refind(found)
    }
    var paths: [ObjectIdentifier: String] = [:]
    var list: [Entry] = []
    for item in items {
      if !list.isEmpty && !found.query.content.isEmpty {
        list.append(Entry(name: "", isDir: false, data: FoundLine(.blank)))
      }
      let file = Entry(
        name: context.basename(item.path), isDir: false, size: item.size, modified: item.modified,
        executable: (item.mode ?? 0) & 0x49 != 0, mode: item.mode.map { $0 & 0xfff }, data: foundData(item)
      )
      paths[ObjectIdentifier(file)] = item.path
      list.append(file)
      list += item.lines.map { Entry(name: "", isDir: false, data: $0) }
    }
    foundPaths = paths
    return list
  }

  override var escapeLabel: String? { found == nil ? nil : tr("find.close") }

  /// 検索の結果を閉じて、元のフォルダーの一覧に戻る。マークはそのまま残す。
  override func closeByEscape() async {
    guard let found else {
      return
    }
    clearFound()
    resetCursor()
    await load(focus: found.focus)
  }

  /// 検索の結果で使えるキー（カーソル移動・Enter・E・マーク・Esc）。
  static let foundKeys: Set<String> = [
    "up", "down", "pageUp", "pageDown", "home", "end", "enter", "char:e", "char: ", "char:　", "escape",
  ]

  /// 検索の結果で使えるコマンド（Enter・E）。
  var foundCommands: [Operation: Command] { [.enter: EnterCommand(), .edit: PathEdit()] }

  /// 検索の結果を出しているときの、上の場所の行。
  var foundLocation: String { tr("find.location", ["count": found?.paths.count ?? 0, "path": found?.query.root ?? ""]) }

  /// 合った行・前後の行にはカーソルが乗らず、マークもできない。
  override func selectable(_ entry: Entry) -> Bool { !(entry.data is FoundLine) }

  override func markable(_ entry: Entry) -> Bool { !(entry.data is FoundLine) }

  /// 結果のファイルのマークは、そのファイルのあるフォルダーのものにする（閉じたあと、そのフォルダーを開けばマークが見える）。
  override func markFor(_ entry: Entry) -> Mark { found == nil ? super.markFor(entry) : Mark(entry, context.dirname(pathOf(entry))) }

  /// 検索の結果は、探し始めたフォルダーからの相対パスで出し、合った行と前後の行はその下に字下げして出す。
  override func drawRow(_ screen: Screen, _ entry: Entry, _ x: Int, _ y: Int, _ width: Int, _ style: Style, marked: Bool) {
    guard let found else {
      super.drawRow(screen, entry, x, y, width, style, marked: marked)
      return
    }
    if let line = entry.data as? FoundLine {
      switch line.kind {
      case .gap:
        screen.text(x + 4, y, "…", style.copyWith(fg: Palette.muted))
        return
      case .more:
        screen.text(x + 4, y, truncate(tr("find.more"), max(0, width - 4)), style.copyWith(fg: Palette.muted))
        return
      case .blank:
        return
      case .line:
        break
      }
      let label = padLeft(String(line.number), 6) + ": "
      screen.text(x + 4, y, label, style.copyWith(fg: line.matched ? Palette.lime : Palette.muted, bold: line.matched))
      drawFoundText(screen, line, x + 4 + textWidth(label), y, x + width, style)
      return
    }
    let relative = Entry(
      name: context.relative(pathOf(entry), from: found.query.root), isDir: entry.isDir, size: entry.size, modified: entry.modified,
      executable: entry.executable, mode: entry.mode, isLink: entry.isLink, data: entry.data
    )
    super.drawRow(screen, relative, x, y, width, style, marked: marked)
  }

  /// 合った行・前後の行の中身を [x] から [limit] の手前まで描く。合った部分は検索の色（find.match）の太字にする。
  private func drawFoundText(_ screen: Screen, _ line: FoundLine, _ x: Int, _ y: Int, _ limit: Int, _ style: Style) {
    let base = style.copyWith(fg: line.matched ? Palette.text : Palette.muted)
    let characters = Array(line.text)
    // 合った部分とそれ以外に分ける。
    var parts: [(text: ArraySlice<Character>, hit: Bool)] = []
    var position = 0
    for range in line.matches where range.lowerBound >= position && range.upperBound <= characters.count {
      parts.append((characters[position..<range.lowerBound], false))
      parts.append((characters[range], true))
      position = range.upperBound
    }
    parts.append((characters[position...], false))
    var col = x
    for part in parts where !part.text.isEmpty {
      // タブは空白にし、制御文字は出さない（桁がずれないように）。
      let text = String(String(part.text).replacingOccurrences(of: "\t", with: "    ").unicodeScalars.map { $0.value < 0x20 ? " " : Character($0) })
      guard col < limit else {
        return
      }
      let shown = truncate(text, limit - col)
      col += screen.text(col, y, shown, part.hit ? base.copyWith(fg: Palette.findMatch, bold: true) : base)
      if shown != text {
        return
      }
    }
  }
}
