import Foundation

/// F・F9 の検索の条件。
nonisolated struct FindQuery: Sendable {
  /// 探し始めるフォルダー（絶対パス）。この下の全フォルダーを探す。
  let root: String

  /// ファイルの中身の正規表現。空なら中身は見ない（名前と拡張子だけで探す）。
  /// ローカルは ICU（NSRegularExpression）、SSH・Container は接続先の grep -E で照らす。
  let content: String

  /// 名前に含む文字列。どれか1つを含むファイルだけ。空なら絞らない。
  let names: [String]

  /// 拡張子（「.」なし）。どれかで終わるファイルだけ。空なら絞らない。
  let extensions: [String]

  /// この名前のフォルダーには入らない。
  let ignored: Set<String>

  /// 中身を探すファイルの大きさの上限。これより大きいファイルは読まずに外す。
  static let contentLimit = 10 * 1024 * 1024

  /// 合った行の前後に出す行数。
  static let context = 1

  /// ファイルごとに出す、合った行の数。これより多く合えば、ほかにもあることを書き添える。
  static let shownMatches = 3

  func matchesName(_ name: String) -> Bool {
    (names.isEmpty || names.contains { name.contains($0) }) && (extensions.isEmpty || extensions.contains { name.hasSuffix(".\($0)") })
  }

  /// 名前で探す（中身は見ない）ときは、名前の合うフォルダーも結果に出す（無視するフォルダーは出さない）。
  var listsFolders: Bool { content.isEmpty && !names.isEmpty }
}

/// 中身の検索で出す1行。
nonisolated struct FoundLine: Sendable {
  enum Kind: Sendable {
    /// ファイルの1行（[number] 行目）。
    case line
    /// 離れた行の間の区切り。
    case gap
    /// 出した分のほかにも、合う行がある。
    case more
    /// ファイルとファイルの間の空行。
    case blank
  }

  init(_ kind: Kind, number: Int = 0, text: String = "", matched: Bool = false, matches: [Range<Int>] = []) {
    self.kind = kind
    self.number = number
    self.text = text
    self.matched = matched
    self.matches = matches
  }

  let kind: Kind
  let number: Int
  let text: String

  /// 正規表現に合った行（ほかは前後の行）。
  let matched: Bool

  /// [text] の中で正規表現に合った部分（文字の位置）。前から順に、重ならない。
  let matches: [Range<Int>]
}

/// 見つけたファイル（名前で探したときはフォルダーも）。中身で探したときは、合った行とその前後の行（[lines]）も持つ。
/// 大きさなどは、接続先で読めなければ nil。
nonisolated struct FoundItem: Sendable {
  let path: String
  let size: Int?
  let modified: Date?
  let mode: Int?
  let lines: [FoundLine]
  var isDir = false
}

/// 見つけたファイルを、パスの順（大文字小文字を区別しない）に並べる。
private nonisolated func sortFound(_ items: [FoundItem]) -> [FoundItem] {
  items.sorted { compareCodeUnits($0.path.lowercased(), $1.path.lowercased()) < 0 }
}

/// 合った行（行番号 [hits]、[FindQuery.shownMatches] 個まで）と、その前後 [FindQuery.context] 行を、出す行にする。
/// 行の中身は [lineAt]（なければ出さない）。[more] なら最後に [FoundLine.Kind.more] を付ける。
/// 合った行の中の合った部分は [regex] で探す（nil なら色を付けない）。
private nonisolated func buildFoundLines(_ hits: [Int], more: Bool, _ lineAt: (Int) -> String?, _ regex: NSRegularExpression?) -> [FoundLine] {
  let matched = Set(hits)
  var result: [FoundLine] = []
  // 最後に出した行。前後の行が重なれば続けて出し、離れていれば区切りを入れる。
  var last = 0
  for hit in hits {
    let start = max(hit - FindQuery.context, last + 1, 1)
    let end = hit + FindQuery.context
    if start > end {
      continue
    }
    for number in start...end {
      guard var text = lineAt(number).map({ String($0.prefix(1000)) }) else {
        continue
      }
      if last > 0 && number > last + 1 {
        result.append(FoundLine(.gap))
      }
      last = number
      // 長すぎる行は、一覧に出しきれないので先だけ持つ（上の prefix）。
      if text.hasSuffix("\r") {
        text.removeLast()
      }
      guard matched.contains(number) else {
        result.append(FoundLine(.line, number: number, text: text))
        continue
      }
      let ranges = (regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []).compactMap { Range($0.range, in: text) }
        .filter { !$0.isEmpty }
        .map { text.distance(from: text.startIndex, to: $0.lowerBound)..<text.distance(from: text.startIndex, to: $0.upperBound) }
      result.append(FoundLine(.line, number: number, text: text, matched: true, matches: ranges))
    }
  }
  if more {
    result.append(FoundLine(.more))
  }
  return result
}

// ---- ローカル ----

/// [query] の条件で、[FindQuery.root] の下を探す。シンボリックリンクはたどらず、結果にも入れない。
/// 開けないフォルダーは飛ばす。Task を取り消すと [CancellationError] を投げる。
/// 名前で候補を集めるときは同じ深さのフォルダーをまとめて並列に読み、中身はファイルごとに並列に照らす。
nonisolated func findFiles(_ query: FindQuery) throws -> [FoundItem] {
  let regex = query.content.isEmpty ? nil : try NSRegularExpression(pattern: query.content)
  let wholeText = try regex.map { try NSRegularExpression(pattern: $0.pattern, options: $0.options.union(.anchorsMatchLines)) }
  // 取り消しの状態は実行時の不可分な値なので、この関数の中なら、並列に動くスレッドから読んでよい。
  return try withUnsafeCurrentTask { task in
    let cancelled = FindCancelFlag(task)
    var candidates: [FoundItem] = []
    var level = [query.root]
    while !level.isEmpty {
      try Task.checkCancellation()
      let dirs = level
      let scanned = FindSlots<(folders: [String], items: [FoundItem])>(dirs.count, ([], []))
      DispatchQueue.concurrentPerform(iterations: dirs.count) { index in
        if !cancelled.isSet {
          scanned.set(index, scanFolder(dirs[index], query))
        }
      }
      if cancelled.isSet {
        throw CancellationError()
      }
      level = []
      for (folders, items) in scanned.values {
        level += folders
        candidates += items
      }
    }
    guard let regex, let wholeText else {
      return sortFound(candidates)
    }
    // 中身は、ファイルを順に配る（大きなフォルダーが1つのスレッドに偏らないように）。
    let files = candidates
    let workers = max(1, ProcessInfo.processInfo.activeProcessorCount)
    let found = FindSlots<[FoundItem]>(workers, [])
    DispatchQueue.concurrentPerform(iterations: workers) { worker in
      var items: [FoundItem] = []
      for index in stride(from: worker, to: files.count, by: workers) {
        if cancelled.isSet {
          return
        }
        let file = files[index]
        let stat = lstatPath(file.path)
        if let lines = matchingLines(file.path, stat, regex, wholeText), !lines.isEmpty {
          items.append(localItem(file.path, stat, lines))
        }
      }
      found.set(worker, items)
    }
    if cancelled.isSet {
      throw CancellationError()
    }
    return sortFound(found.values.flatMap { $0 })
  }
}

/// [dir] の直下を見て、入るフォルダーと、名前の合うもの（中身はまだ見ない）。
private nonisolated func scanFolder(_ dir: String, _ query: FindQuery) -> (folders: [String], items: [FoundItem]) {
  var folders: [String] = []
  var items: [FoundItem] = []
  for (name, kind) in readEntries(dir) ?? [] {
    let path = dir.hasSuffix("/") ? dir + name : dir + "/" + name
    switch kind {
    case .directory:
      if !query.ignored.contains(name) {
        folders.append(path)
        if query.listsFolders && query.matchesName(name) {
          items.append(localItem(path, lstatPath(path), [], isDir: true))
        }
      }
    case .file:
      if query.matchesName(name) {
        // 中身で探すときは、大きさなどは照らすときに読む。
        items.append(query.content.isEmpty ? localItem(path, lstatPath(path), []) : FoundItem(path: path, size: nil, modified: nil, mode: nil, lines: []))
      }
    default:
      continue
    }
  }
  return (folders, items)
}

/// 並列に探しているあいだの取り消し（呼んだ Task の取り消しを、ほかのスレッドから見る）。Task の外で呼ばれたら取り消さない。
private final nonisolated class FindCancelFlag: @unchecked Sendable {
  init(_ task: UnsafeCurrentTask?) { self.task = task }
  private let task: UnsafeCurrentTask?
  var isSet: Bool { task?.isCancelled ?? false }
}

/// 並列に動く処理の結果を、添え字ごとに受け取る。
private final nonisolated class FindSlots<Value>: @unchecked Sendable {
  init(_ count: Int, _ initial: Value) { buffer = Array(repeating: initial, count: count) }
  private let lock = NSLock()
  private var buffer: [Value]
  func set(_ index: Int, _ value: Value) { lock.withLock { buffer[index] = value } }
  var values: [Value] { lock.withLock { buffer } }
}

/// [dir] の子の名前と種類。種類は readdir の d_type で決め（1件ずつ lstat すると遅い）、わからなければ lstat で調べる。
/// シンボリックリンクなど、ファイルでもフォルダーでもないものは nil。開けなければ全体が nil。
private nonisolated func readEntries(_ dir: String) -> [(name: String, kind: FileSystemEntityType?)]? {
  guard let handle = opendir(dir) else {
    return nil
  }
  defer { closedir(handle) }
  var result: [(name: String, kind: FileSystemEntityType?)] = []
  while let entry = readdir(handle) {
    let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
      String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
    }
    if name == "." || name == ".." {
      continue
    }
    let kind: FileSystemEntityType?
    switch Int32(entry.pointee.d_type) {
    case DT_DIR: kind = .directory
    case DT_REG: kind = .file
    case DT_UNKNOWN:
      let type = lstatPath(dir.hasSuffix("/") ? dir + name : dir + "/" + name).type
      kind = type == .directory || type == .file ? type : nil
    default: kind = nil
    }
    result.append((name, kind))
  }
  return result
}

private nonisolated func localItem(_ path: String, _ stat: FileStat, _ lines: [FoundLine], isDir: Bool = false) -> FoundItem {
  FoundItem(path: path, size: stat.size, modified: stat.modified, mode: stat.mode, lines: lines, isDir: isDir)
}

/// 一度見つけたファイル・フォルダー [paths] を読み直す（エディタで書き換えたあとなど）。なくなったものは外し、
/// 中身で探したときは合う行を探し直す（合わなくなっても一覧には残す）。
nonisolated func refindFiles(_ paths: [String], _ query: FindQuery) -> [FoundItem] {
  let regex = query.content.isEmpty ? nil : try? NSRegularExpression(pattern: query.content)
  return paths.compactMap { path in
    let stat = lstatPath(path)
    if stat.type == .directory && query.listsFolders {
      return localItem(path, stat, [], isDir: true)
    }
    guard stat.type == .file else {
      return nil
    }
    return localItem(path, stat, regex.flatMap { matchingLines(path, stat, $0) } ?? [])
  }
}

/// [path] の中で [regex] に合う行（[FindQuery.shownMatches] 行まで）と、その前後の行。
/// それより多く合えば、最後に [FoundLine.Kind.more] を付ける（1つ多く見つけたところで探すのをやめる）。
/// 大きすぎるファイル・読めないファイル・バイナリ（先頭に NUL がある）は nil。
private nonisolated func matchingLines(_ path: String, _ stat: FileStat, _ regex: NSRegularExpression) -> [FoundLine]? {
  guard let wholeText = try? NSRegularExpression(pattern: regex.pattern, options: regex.options.union(.anchorsMatchLines)) else {
    return nil
  }
  return matchingLines(path, stat, regex, wholeText)
}

/// [matchingLines]。[wholeText] は、ファイル全体で先に照らすための、^ $ を行ごとにした同じ正規表現。
private nonisolated func matchingLines(_ path: String, _ stat: FileStat, _ regex: NSRegularExpression, _ wholeText: NSRegularExpression) -> [FoundLine]? {
  guard stat.size <= FindQuery.contentLimit, let data = readTextFile(path) else {
    return nil
  }
  // ほとんどのファイルは合わないので、先にファイル全体で1回だけ照らし、合わなければ行に分けない。
  // ^ $ は各行の始めと終わりに合わせる（[wholeText]）。行をまたいで合うこともあるが、そのときは下の行ごとの照合で外れる。
  let text = String(decoding: data, as: UTF8.self)
  guard wholeText.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil else {
    return []
  }
  var lines = text.components(separatedBy: "\n")
  if lines.last == "" {
    lines.removeLast()
  }
  var hits: [Int] = []
  for (index, line) in lines.enumerated() where regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
    hits.append(index + 1)
    if hits.count > FindQuery.shownMatches {
      break
    }
  }
  return buildFoundLines(
    Array(hits.prefix(FindQuery.shownMatches)), more: hits.count > FindQuery.shownMatches,
    { $0 >= 1 && $0 <= lines.count ? lines[$0 - 1] : nil }, regex
  )
}

/// [path] の中身。先頭 [textProbe] バイトが UTF-8（ASCII を含む）でないか、NUL を含めば、テキストでないとして
/// そこで閉じて nil（最後まで読まない）。読めなくても nil。
private nonisolated func readTextFile(_ path: String) -> Data? {
  guard let handle = FileHandle(forReadingAtPath: path) else {
    return nil
  }
  defer { try? handle.close() }
  guard var data = try? handle.read(upToCount: textProbe) else {
    return Data()
  }
  guard looksLikeText(data, truncated: data.count == textProbe) else {
    return nil
  }
  if data.count == textProbe, let rest = try? handle.readToEnd() {
    data.append(rest)
  }
  return data
}

/// テキストかを見る、ファイルの先頭の大きさ。
nonisolated private let textProbe = 1024

/// [head] が NUL を含まない UTF-8 か。[truncated] なら、末尾で途切れた1文字（3バイトまで）は不問にする。
nonisolated func looksLikeText(_ head: Data, truncated: Bool) -> Bool {
  if head.contains(0) {
    return false
  }
  for cut in 0...(truncated ? min(3, head.count) : 0) where String(bytes: head.dropLast(cut), encoding: .utf8) != nil {
    return true
  }
  return false
}

// ---- SSH・Container（接続先の find と grep） ----

/// ファイル内容の正規表現が通らなかった（ローカルは ICU、接続先は grep -E で）。
nonisolated struct InvalidFindPattern: Error {}

/// 接続先で [query] の条件で探す。接続先の find でたどり、中身は grep -E で照らす（1回の実行で済ませる）。
/// 正規表現が grep で通らなければ [InvalidFindPattern]。
func findRemoteFiles(_ ssh: Ssh, _ query: FindQuery) async throws -> [FoundItem] {
  let out = try await ssh.run(remoteFindScript(query))
  guard let items = parseRemoteFound(out, query) else {
    throw InvalidFindPattern()
  }
  return items
}

/// find の -name に、[s] をそのままの文字として書く（* ? [ \ の前に \ を付ける）。
private nonisolated func globLiteral(_ s: String) -> String {
  var out = ""
  for c in s {
    if "*?[\\".contains(c) {
      out.append("\\")
    }
    out.append(c)
  }
  return out
}

/// 接続先の sh で実行する1行。出力は、ファイルごとに「\036パス\037大きさ 更新時刻 権限\037grep -n の出力」（フォルダーはパスの末尾に「/」）。
/// 正規表現が grep -E で通らなければ \025 だけを出す。
///
/// - シンボリックリンクは find の既定でたどらず、-type f で結果からも外れる。無視するフォルダーは -prune で入らない。
/// - 中身で探すときは、10MB 以下のファイルだけを、まとめて grep -l で絞ってから、合ったファイルごとに grep -n で行を取る。
///   grep の -I（バイナリを外す）・-C（前後の行）・-m（合った数で止める）は、使えるときだけ使う（BusyBox にはないことがある）。
/// - 大きさなどは stat -c で読む（なければ出さない）。
nonisolated func remoteFindScript(_ query: FindQuery) -> String {
  var filters: [String] = []
  if !query.ignored.isEmpty {
    let names = query.ignored.sorted().map { "-name \(shQuote($0))" }.joined(separator: " -o ")
    filters.append("\\( -type d \\( \(names) \\) \\) -prune -o")
  }
  // 名前で探すときはフォルダーも出す（探し始めるフォルダー「.」は除く）。
  filters.append(query.listsFolders ? "\\( -type f -o \\( -type d ! -name . \\) \\)" : "-type f")
  if !query.names.isEmpty {
    filters.append("\\( " + query.names.map { "-name \(shQuote("*\(globLiteral($0))*"))" }.joined(separator: " -o ") + " \\)")
  }
  if !query.extensions.isEmpty {
    filters.append("\\( " + query.extensions.map { "-name \(shQuote("*.\(globLiteral($0))"))" }.joined(separator: " -o ") + " \\)")
  }
  // フォルダーは、パスの末尾に「/」を付けて見分ける。
  let record = "s=$(stat -c '%s %Y %a' -- \"$f\" 2>/dev/null); [ -d \"$f\" ] && f=\"$f/\"; printf '\\036%s\\037%s\\037' \"$f\" \"$s\""
  var script = "cd \(shQuote(query.root)) || exit 1; "
  let inner: String
  if query.content.isEmpty {
    inner = "for f do \(record); done"
    script += "find . \(filters.joined(separator: " ")) -exec sh -c \(shQuote(inner)) sh {} + 2>/dev/null; true"
    return script
  }
  // -size は KB 単位で切り上げて比べるので、10MB ちょうどまでが入る。
  filters.append("-size -\(FindQuery.contentLimit / 1024 + 1)k")
  inner = "p=$1; shift; grep -l $I -E -e \"$p\" -- \"$@\" 2>/dev/null | while IFS= read -r f; do \(record); "
    + "grep -n $I $C $M -E -e \"$p\" -- \"$f\" 2>/dev/null; done"
  script += "printf '' | grep -E -e \(shQuote(query.content)) >/dev/null 2>&1; [ $? -le 1 ] || { printf '\\025'; exit 0; }; "
  script += "I=; printf 'x\\n' | grep -I x >/dev/null 2>&1 && I=-I; "
  script += "C=; printf 'x\\n' | grep -C \(FindQuery.context) x >/dev/null 2>&1 && C='-C \(FindQuery.context)'; "
  script += "M=; printf 'x\\n' | grep -m 1 x >/dev/null 2>&1 && M='-m \(FindQuery.shownMatches + 1)'; export I C M; "
  script += "find . \(filters.joined(separator: " ")) -exec sh -c \(shQuote(inner)) sh \(shQuote(query.content)) {} + 2>/dev/null; true"
  return script
}

/// [remoteFindScript] の出力を読む。正規表現が通らなかったときは nil。
/// 中身で探したときは、grep -n の「行番号:中身」（合った行）・「行番号-中身」（前後の行）から出す行を作る。
/// 中身に NUL がある（-I が使えずバイナリが混ざった）ファイルは外す。
nonisolated func parseRemoteFound(_ out: Data, _ query: FindQuery) -> [FoundItem]? {
  if out.first == 0x15 {
    return nil
  }
  // 色を付けるための正規表現。grep -E の書き方が ICU で通らなければ、色を付けない。
  let regex = query.content.isEmpty ? nil : try? NSRegularExpression(pattern: query.content)
  var items: [FoundItem] = []
  for record in out.split(separator: 0x1E, omittingEmptySubsequences: true) {
    let fields = record.split(separator: 0x1F, maxSplits: 2, omittingEmptySubsequences: false)
    guard fields.count >= 2 else {
      continue
    }
    var relative = String(decoding: fields[0], as: UTF8.self)
    let isDir = relative.hasSuffix("/")
    if isDir {
      relative.removeLast()
    }
    let path = PathContext.posix.join(query.root, relative.hasPrefix("./") ? String(relative.dropFirst(2)) : relative)
    let stat = String(decoding: fields[1], as: UTF8.self).split(separator: " ")
    let size = stat.count == 3 ? Int(stat[0]) : nil
    let modified = stat.count == 3 ? Double(stat[1]).map { Date(timeIntervalSince1970: $0) } : nil
    let mode = stat.count == 3 ? Int(stat[2], radix: 8) : nil
    guard !query.content.isEmpty else {
      items.append(FoundItem(path: path, size: size, modified: modified, mode: mode, lines: [], isDir: isDir))
      continue
    }
    let grep = fields.count == 3 ? fields[2] : Data()
    if grep.contains(0) {
      continue
    }
    var lines: [Int: String] = [:]
    var hits: [Int] = []
    for line in String(decoding: grep, as: UTF8.self).components(separatedBy: "\n") {
      let digits = line.prefix { $0.isASCII && $0.isNumber }
      guard let number = Int(digits), let separator = line.dropFirst(digits.count).first, separator == ":" || separator == "-" else {
        continue
      }
      lines[number] = String(line.dropFirst(digits.count + 1))
      if separator == ":" {
        hits.append(number)
      }
    }
    hits.sort()
    if hits.isEmpty {
      continue
    }
    let shown = buildFoundLines(
      Array(hits.prefix(FindQuery.shownMatches)), more: hits.count > FindQuery.shownMatches, { lines[$0] }, regex
    )
    items.append(FoundItem(path: path, size: size, modified: modified, mode: mode, lines: shown))
  }
  return sortFound(items)
}

// ---- 小窓とコマンド ----

/// F・F9 の検索の条件を書く小窓。↑↓・Tab で行を移り、文字はその行の入力欄に入る。Enter で探し、Esc でやめる。
final class FindDialog: Modal {
  struct Input {
    let path: String
    let content: String
    let names: String
    let extensions: String
    let ignored: String
  }

  init(_ close: @escaping (Input?) -> Void) {
    self.close = close
    fields = [
      InputField(initial: "./"),
      InputField(),
      InputField(),
      InputField(),
      InputField(initial: "vendor ios android node_modules"),
    ]
    super.init(tr("find.title"))
  }

  let close: (Input?) -> Void
  /// 検索パス・ファイル内容・ファイル名・対象拡張子・無視するディレクトリ名。
  private let fields: [InputField]
  private(set) var row = 0

  override var focusedField: InputField? { fields[row] }

  var result: Input {
    let values = fields.map { $0.value.trimmingCharacters(in: .whitespaces) }
    return Input(path: values[0], content: values[1], names: values[2], extensions: values[3], ignored: values[4])
  }

  /// ほかの入力欄と同じ幅（[InputDialog.defaultWidth]）。
  override func preferredWidth(_ screen: Screen) -> Int { min(screen.width - 4, InputDialog.defaultWidth) }

  /// 5行・空行・注意書き。
  override func bodyHeight(_ innerWidth: Int) -> Int { 7 }

  override func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ innerWidth: Int) {
    let labels = ["path", "content", "names", "extensions", "ignored"].map { tr("find.\($0)") }
    let labelWidth = min(innerWidth / 3, (labels.map(textWidth).max() ?? 0) + 2)
    let valueWidth = max(0, innerWidth - labelWidth)
    for (index, label) in labels.enumerated() {
      let selected = index == row
      screen.text(x, y + index, truncate(label, labelWidth), background.copyWith(fg: selected ? Palette.text : Palette.muted, bold: selected))
      fields[index].draw(screen, x + labelWidth, y + index, valueWidth, focused: selected)
    }
    screen.text(x, y + labels.count + 1, truncate(tr("find.note"), innerWidth), background.copyWith(fg: Palette.muted))
  }

  override var hints: [(String, String)] {
    [("↑↓", tr("dialogs.hint.move")), ("Enter", tr("find.search")), ("Esc", tr("dialogs.cancel"))]
  }

  override func handleKey(_ key: Key) {
    switch key.name {
    case "escape":
      close(nil)
    case "enter":
      close(result)
    case "up", "backTab":
      row = (row + fields.count - 1) % fields.count
    case "down", "tab":
      row = (row + 1) % fields.count
    default:
      _ = field.handleKey(key)
    }
  }

  private var field: InputField { fields[row] }
}

/// 開いているフォルダーを基準に、条件の小窓（[FindDialog]）で探し、見つけたファイルを窓いっぱいの一覧に出す（F・F9）。
/// 一覧は Esc で閉じ、一覧でつけたマークは元の一覧に引き継ぐ。探し方はタブごとの継承クラスに書く。
class FindCommand: Command {
  override var label: String { "Find" }

  /// 小窓の検索パス [input]（空なら開いているフォルダー）を、探し始めるフォルダーの絶対パスにする。フォルダーでなければ nil。
  func root(_ c: CommandContext, _ input: String) async -> String? { fatalError("root") }

  /// [query] で探す。
  func search(_ c: CommandContext, _ query: FindQuery) async throws -> [FoundItem] { fatalError("search") }

  override func run(_ c: CommandContext) async {
    let pane = c.pane as! PathPane
    guard let input: FindDialog.Input = await c.app.showModal({ close in FindDialog(close) }) else {
      return
    }
    func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
    guard let root = await root(c, input.path) else {
      c.app.showStatus(tr("find.not_folder", ["path": input.path.isEmpty ? "." : input.path]))
      return
    }
    let query = FindQuery(
      root: root,
      content: input.content,
      names: words(input.names),
      extensions: words(input.extensions).map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 },
      ignored: Set(words(input.ignored))
    )
    do {
      let items = try await c.app.withUpdatingProgress(tr("find.searching")) { _ in
        try await self.search(c, query)
      }
      if items.isEmpty {
        c.app.showStatus(tr("find.not_found"))
        return
      }
      await pane.showFound(query, items)
    } catch is CancellationError {
      c.app.showStatus(tr("find.cancelled"))
    } catch is InvalidFindPattern {
      c.app.showStatus(tr("find.invalid_regex", ["pattern": query.content]))
    } catch {
      await c.app.showError(error)
    }
  }
}

/// ローカルを、このアプリ自身でたどって探す（[findFiles]）。
final class LocalFind: FindCommand {
  /// 圧縮ファイルの中では探さない。
  override func available(_ pane: Pane) -> Bool { !((pane as? LocalPane)?.inArchive ?? true) }

  override func root(_ c: CommandContext, _ input: String) async -> String? {
    let pane = c.pane as! LocalPane
    let root = p.normalize(p.join(pane.dir, expandHome(input.isEmpty ? "." : input, homeDir)))
    return statPath(root).type == .directory ? root : nil
  }

  override func search(_ c: CommandContext, _ query: FindQuery) async throws -> [FoundItem] {
    if !query.content.isEmpty {
      // 正しくなければ、探す前に知らせる。
      do {
        _ = try NSRegularExpression(pattern: query.content)
      } catch {
        throw InvalidFindPattern()
      }
    }
    let task = Task.detached { try findFiles(query) }
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }
}

/// SSH の接続先・コンテナの中を、そこの find と grep で探す（[findRemoteFiles]）。
final class RemoteFind: FindCommand {
  /// つないでいて、圧縮ファイルの中でないときだけ。
  override func available(_ pane: Pane) -> Bool {
    guard let pane = pane as? SshPane else { return false }
    return pane.ssh != nil && !pane.inArchive
  }

  override func root(_ c: CommandContext, _ input: String) async -> String? {
    let pane = c.pane as! SshPane
    guard let ssh = pane.ssh else { return nil }
    var path = input.isEmpty ? "." : input
    if path == "~" || path.hasPrefix("~/") {
      guard let home = try? await ssh.home() else { return nil }
      path = expandHome(path, home)
    }
    // 接続先の pwd -P で、あるフォルダーかを確かめる（一覧の場所と同じ書き方になる）。
    return try? await ssh.directory(PathContext.posix.join(pane.dir, path))
  }

  override func search(_ c: CommandContext, _ query: FindQuery) async throws -> [FoundItem] {
    guard let ssh = (c.pane as! SshPane).ssh else { return [] }
    return try await findRemoteFiles(ssh, query)
  }
}
