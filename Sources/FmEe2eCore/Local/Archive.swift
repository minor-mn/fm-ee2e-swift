import Foundation

/// 中をフォルダーのように見られる圧縮ファイルか（.zip / .tar.gz / .tar.xz）。
nonisolated func isBrowsableArchive(_ name: String) -> Bool {
  let lower = name.lowercased()
  return lower.hasSuffix(".zip") || lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tar.xz")
}

/// 圧縮ファイルの中の1項目。
nonisolated struct ArchiveItem: Sendable {
  init(path: String, raw: String?, isDir: Bool, size: Int = 0, modified: Date? = nil, readOptions: [String] = []) {
    self.path = path
    self.raw = raw
    self.isDir = isDir
    self.size = size
    self.modified = modified
    self.readOptions = readOptions
  }

  /// 「/」区切りの中のパス（先頭の ./ と末尾の / は除く）。
  let path: String

  /// 圧縮ファイルに入っている名前そのもの（取り出すときに使う）。中の項目から補ったフォルダーは nil。
  let raw: String?
  let isDir: Bool
  let size: Int
  let modified: Date?

  /// 一覧を読んだときに tar に渡したオプション（名前の文字コード）。取り出すときも同じものを渡す。
  let readOptions: [String]

  var name: String { PathContext.posix.basename(path) }
  var parent: String { PathContext.posix.dirname(path) == "." ? "" : PathContext.posix.dirname(path) }
}

/// macOS の tar（libarchive）で一覧を読む。zip・tar.gz・tar.xz を同じように扱える。
/// Windows で作った zip は名前が CP932 のことがあるので、UTF-8 として読めない名前があれば CP932 で読み直す。
func listArchive(_ archive: String) async throws -> [ArchiveItem] {
  let output = try await list(archive, [])
  if archive.lowercased().hasSuffix(".zip") && hasBadName(output) {
    let cp932 = ["--options", "zip:hdrcharset=CP932"]
    do {
      let retried = try await list(archive, cp932)
      if !hasBadName(retried) {
        return parseTarListing(retried, Date(), readOptions: cp932)
      }
    } catch is FileSystemException {
      // CP932 でも読めなければ、最初の一覧を使う。
    }
  }
  return parseTarListing(output, Date())
}

private func list(_ archive: String, _ options: [String]) async throws -> String {
  let result = try await runProcess(
    "/usr/bin/tar",
    options + ["-tvf", archive],
    // 日本語の名前をそのまま出させ、月の名前を英語にする。
    environment: ["LC_ALL": "en_US.UTF-8"]
  )
  if result.exitCode != 0 {
    throw FileSystemException(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), archive)
  }
  return result.stdout
}

private nonisolated let badEscape = try! Regex(#"\\[0-3][0-7]{2}"#).matchingSemantics(.unicodeScalar)

/// tar は UTF-8 にならないバイトを「\223」の形か、そのままのバイト（読むと U+FFFD）で出す。
private nonisolated func hasBadName(_ output: String) -> Bool {
  output.unicodeScalars.contains("\u{FFFD}") || output.firstMatch(of: badEscape) != nil
}

private nonisolated let line = try! Regex(
  #"^([-dlhcbps])\S*\s+\d+\s+\S+\s+\S+\s+(\d+)\s+([A-Z][a-z]{2})\s+(\d{1,2})\s+(\d{1,2}:\d{2}|\d{4})\s(.*)$"#
).matchingSemantics(.unicodeScalar)

private nonisolated let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

/// 正規表現の [i] 番目のグループ（なければ nil）。
nonisolated func regexGroup(_ m: Regex<AnyRegexOutput>.Match, _ i: Int) -> String? {
  m.output[i].substring.map(String.init)
}

/// Dart の DateTime(year, month, day, hour, minute) と同じ、この Mac の時間帯の日時。
nonisolated func localDateTime(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = .current
  return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// [date] の（グレゴリオ暦の）年。
nonisolated func yearOf(_ date: Date) -> Int {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = .current
  return calendar.component(.year, from: date)
}

/// `tar -tv` の出力（ls -l の形）を読む。年がなく時刻だけの日付は、[now] から半年以内として年を補う。
nonisolated func parseTarListing(_ output: String, _ now: Date, readOptions: [String] = []) -> [ArchiveItem] {
  var items: [ArchiveItem] = []
  for text in output.components(separatedBy: "\n") {
    guard let m = text.firstMatch(of: line) else {
      continue
    }
    let type = regexGroup(m, 1)!
    var name = regexGroup(m, 6)!
    if type == "l" {
      // シンボリックリンクは「名前 -> 先」と出る。
      if let arrow = name.range(of: " -> ", options: .literal) {
        name = String(name[..<arrow.lowerBound])
      }
    }
    let raw = name
    let isDir = type == "d" || name.hasSuffix("/")
    while name.hasPrefix("./") {
      name = String(name.unicodeScalars.dropFirst(2))
    }
    while name.hasSuffix("/") {
      name = String(name.unicodeScalars.dropLast())
    }
    if name.isEmpty || name == "." {
      continue
    }
    items.append(
      ArchiveItem(
        path: name,
        raw: raw,
        isDir: isDir,
        size: Int(regexGroup(m, 2)!) ?? 0,
        modified: date(m, now),
        readOptions: readOptions
      )
    )
  }
  return items
}

private nonisolated func date(_ m: Regex<AnyRegexOutput>.Match, _ now: Date) -> Date? {
  let month = (months.firstIndex(of: regexGroup(m, 3)!) ?? -1) + 1
  let day = Int(regexGroup(m, 4)!)!
  let timeOrYear = regexGroup(m, 5)!
  if month == 0 {
    return nil
  }
  if !timeOrYear.contains(":") {
    return localDateTime(Int(timeOrYear)!, month, day)
  }
  let parts = timeOrYear.split(separator: ":").map { Int($0)! }
  let (hour, minute) = (parts[0], parts[1])
  let year = yearOf(now)
  let date = localDateTime(year, month, day, hour, minute)
  // 先の日付になるなら前の年。
  return date > now.addingTimeInterval(86400) ? localDateTime(year - 1, month, day, hour, minute) : date
}

/// [dir] の直下の項目。中のファイルからしか分からないフォルダーも補う。
nonisolated func archiveChildren(_ items: [ArchiveItem], _ dir: String) -> [ArchiveItem] {
  // 書いた順に並べる（Dart の Map と同じ）。
  var order: [String] = []
  var children: [String: ArchiveItem] = [:]
  let prefix = dir.isEmpty ? "" : "\(dir)/"
  for item in items {
    guard item.path.utf8.starts(with: prefix.utf8) else {
      continue
    }
    let rest = String(item.path.utf8.dropFirst(prefix.utf8.count))!
    if let slash = rest.unicodeScalars.firstIndex(of: "/") {
      let name = String(rest.unicodeScalars[..<slash])
      if children[name] == nil {
        order.append(name)
        children[name] = ArchiveItem(path: "\(prefix)\(name)", raw: nil, isDir: true)
      }
    } else {
      if children[rest] == nil {
        order.append(rest)
      }
      children[rest] = item
    }
  }
  return order.map { children[$0]! }
}

/// [archive] を丸ごと [dest] に展開する。[items] は [listArchive] の結果で、名前の文字コード（CP932 など）を合わせる。
/// [keepExisting] なら、すでにあるファイルは上書きしない。
func extractArchive(_ archive: String, _ items: [ArchiveItem], _ dest: String, keepExisting: Bool) async throws {
  let result = try await runProcess(
    "/usr/bin/tar",
    (items.first?.readOptions ?? []) + ["-xf", archive, "-C", dest] + (keepExisting ? ["-k"] : [])
  )
  if result.exitCode != 0 {
    throw FileSystemException(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), archive)
  }
}

/// tar・bsdtar が名前をワイルドカードとして扱わないよう、記号をエスケープする。
nonisolated func escapeTarPattern(_ raw: String) -> String {
  var out = String.UnicodeScalarView()
  for c in raw.unicodeScalars {
    if "\\*?[]".unicodeScalars.contains(c) {
      out.append("\\")
    }
    out.append(c)
  }
  return String(out)
}

/// [item] を [dest] に取り出し、取り出したファイルのパスを返す。
func extractArchiveItem(_ archive: String, _ item: ArchiveItem, _ dest: String) async throws -> String {
  guard let raw = item.raw else {
    throw FileSystemException("取り出せません", item.path)
  }
  // tar は名前をワイルドカードとして扱うので、記号をエスケープする。
  let pattern = escapeTarPattern(raw)
  let result = try await runProcess("/usr/bin/tar", item.readOptions + ["-xf", archive, "-C", dest, "--", pattern])
  if result.exitCode != 0 {
    throw FileSystemException(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), item.path)
  }
  return p.join(dest, item.path)
}

/// 圧縮の形式。
nonisolated enum ArchiveFormat: CaseIterable, Sendable {
  case zip
  case tarGz
  case tarXz

  var label: String {
    switch self {
    case .zip: "zip"
    case .tarGz: "tar.gz"
    case .tarXz: "tar.xz"
    }
  }

  var `extension`: String {
    switch self {
    case .zip: ".zip"
    case .tarGz: ".tar.gz"
    case .tarXz: ".tar.xz"
    }
  }

  /// tar に渡す形式のオプション。
  var tarOptions: [String] {
    switch self {
    case .zip: ["--format", "zip"]
    case .tarGz: ["-z"]
    case .tarXz: ["-J"]
    }
  }
}

/// [paths] をまとめて [output] に [format] で圧縮する。
/// 中の名前は各項目の名前から始める。項目は別々のフォルダーにあってよい。失敗したら作りかけの [output] を消す。
func compressPaths(_ paths: [String], _ output: String, _ format: ArchiveFormat) async throws {
  var args = ["-c"] + format.tarOptions + ["-f", output]
  for path in paths {
    let base = p.basename(path)
    // 「-」で始まる名前をオプションと誤認させない。
    args += ["-C", p.dirname(path), base.hasPrefix("-") ? "./\(base)" : base]
  }
  // macOS の tar は拡張属性などを「._名前」の項目として入れるので、入れないようにする。
  let result = try await runProcess("/usr/bin/tar", args, environment: ["COPYFILE_DISABLE": "1"])
  if result.exitCode != 0 {
    // 作られていなければ何もしない。
    _ = unlink(output)
    throw FileSystemException(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), output)
  }
}
