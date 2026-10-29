import Foundation

/// 接続先で圧縮ファイルの中を読む道具。接続先にあるものを使う。
nonisolated enum RemoteArchiveTool: Sendable {
  /// libarchive の tar。zip・tar.gz・tar.xz を同じように扱える。zip はこれを先に使う。
  case bsdtar

  /// tar（GNU・BusyBox など）。tar.gz・tar.xz だけ。
  case tar

  /// unzip（一覧は zipinfo の形）。zip だけ。
  case unzip
}

/// 接続先の圧縮ファイル（読むだけ）。開いたときに一度だけ一覧を読む。
final class RemoteArchive {
  private init(_ ssh: Ssh, _ path: String, _ tool: RemoteArchiveTool, _ items: [ArchiveItem]) {
    self.ssh = ssh
    self.path = path
    self.tool = tool
    self.items = items
  }

  let ssh: Ssh

  /// 接続先の圧縮ファイルのパス。
  let path: String
  let tool: RemoteArchiveTool
  let items: [ArchiveItem]

  /// [path] の一覧を、接続先にある道具で読む。使える道具がなければ [SshException]。
  static func open(_ ssh: Ssh, _ path: String) async throws -> RemoteArchive {
    let zip = path.lowercased().hasSuffix(".zip")
    let found = String(
      decoding: try await ssh.run(
        "has() { command -v \"$1\" >/dev/null 2>&1; }; "
          + "\(zip ? "if has bsdtar; then echo bsdtar; elif has unzip; then echo unzip; fi" : "has tar && echo tar"); true"
      ),
      as: UTF8.self
    )
    let tool: RemoteArchiveTool
    switch found.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "bsdtar": tool = .bsdtar
    case "tar": tool = .tar
    case "unzip": tool = .unzip
    default:
      throw SshException(
        zip ? "\(ssh.host) に bsdtar も unzip もないので、zip を扱えません。" : "\(ssh.host) に tar がないので、tar.gz・tar.xz を扱えません。"
      )
    }
    let archive = shQuote(path)
    // 日本語の名前をそのまま出させ、月の名前を英語にする（C.UTF-8 がなければ C のまま動く）。
    let script =
      switch tool {
      case .bsdtar: "LC_ALL=C.UTF-8 bsdtar -tvf \(archive)"
      case .tar: "LC_ALL=C.UTF-8 tar -t -v \(compression(path)) -f \(archive)"
      case .unzip: "LC_ALL=C.UTF-8 unzip -Z -l -T \(archive)"
      }
    let output = String(decoding: try await ssh.run(script), as: UTF8.self)
    let now = Date()
    let items =
      switch tool {
      case .bsdtar: parseTarListing(output, now)
      // GNU・BusyBox の tar は日付が「2026-10-29 09:00」の形。macOS の tar（bsdtar）なら ls -l の形。
      case .tar: parseGnuTarListing(output) + parseTarListing(output, now)
      case .unzip: parseZipinfoListing(output)
      }
    return RemoteArchive(ssh, path, tool, items)
  }

  /// 丸ごと接続先の [dest] フォルダーに展開する。[keepExisting] なら、すでにあるファイルは上書きしない。
  func extractAll(_ dest: String, keepExisting: Bool) async throws {
    let archive = shQuote(path)
    let to = shQuote(dest)
    let script =
      switch tool {
      case .bsdtar: "bsdtar -xf \(archive) -C \(to)\(keepExisting ? " -k" : "")"
      // GNU tar の -k は、すでにあるファイルをエラーにして失敗で終わるので、あれば --skip-old-files で飛ばす（BusyBox には -k だけ）。
      case .tar:
        "\(keepExisting ? "if tar --help 2>&1 | grep -q -- --skip-old-files; then k=--skip-old-files; else k=-k; fi; " : "")"
          + "tar -x \(compression(path))\(keepExisting ? " $k" : "") -f \(archive) -C \(to)"
      case .unzip: "unzip -qq \(keepExisting ? "-n" : "-o") \(archive) -d \(to)"
      }
    try await ssh.run(script)
  }

  /// [item] を接続先の [dest] フォルダーに取り出し、取り出したファイルのパスを返す。
  func extract(_ item: ArchiveItem, _ dest: String) async throws -> String {
    guard let raw = item.raw else {
      throw SshException("「\(item.path)」は取り出せません。")
    }
    let archive = shQuote(path)
    let to = shQuote(dest)
    let script =
      switch tool {
      // bsdtar は名前をワイルドカードとして扱うので、記号をエスケープする。
      case .bsdtar: "bsdtar -xf \(archive) -C \(to) -- \(shQuote(escapeTarPattern(raw)))"
      // GNU tar は取り出す名前をワイルドカードとして扱わない。
      case .tar: "tar -x \(compression(path)) -f \(archive) -C \(to) -- \(shQuote(raw))"
      // unzip は名前をワイルドカードとして扱うので、記号を [] で囲む。
      case .unzip: "unzip -qq -o \(archive) \(shQuote(bracketUnzipPattern(raw))) -d \(to)"
      }
    try await ssh.run(script)
    return PathContext.posix.join(dest, item.path)
  }
}

private nonisolated func bracketUnzipPattern(_ raw: String) -> String {
  var out = String.UnicodeScalarView()
  for c in raw.unicodeScalars {
    if c == "*" || c == "?" || c == "[" {
      out.append(contentsOf: "[\(c)]".unicodeScalars)
    } else {
      out.append(c)
    }
  }
  return String(out)
}

/// tar.gz・tar.xz を tar で読むときの形式のオプション。
private nonisolated func compression(_ path: String) -> String { path.lowercased().hasSuffix(".tar.xz") ? "-J" : "-z" }

/// GNU・BusyBox の `tar -tv` の出力を読む（「-rw-r--r-- user/group 123 2026-10-29 09:00 名前」の形）。
nonisolated func parseGnuTarListing(_ output: String) -> [ArchiveItem] {
  output.components(separatedBy: "\n").compactMap { line in
    guard let m = line.firstMatch(of: gnuLine) else {
      return nil
    }
    return listedItem(m)
  }
}

private nonisolated let gnuLine = try! Regex(
  #"^([-dlhcbps])\S*\s+\S+\s+(\d+)\s+(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2})(?::\d{2})?\s(.*)$"#
).matchingSemantics(.unicodeScalar)

/// `unzip -Z -l -T`（zipinfo）の出力を読む（「-rw-r--r-- 3.0 unx 123 tx 45 defN 20261029.090000 名前」の形）。
nonisolated func parseZipinfoListing(_ output: String) -> [ArchiveItem] {
  output.components(separatedBy: "\n").compactMap { line in
    guard let m = line.firstMatch(of: zipinfoLine) else {
      return nil
    }
    return listedItem(m)
  }
}

private nonisolated let zipinfoLine = try! Regex(
  #"^([-dl])\S*\s+\S+\s+\S+\s+(\d+)\s+\S+\s+\d+\s+\S+\s+(\d{4})(\d{2})(\d{2})\.(\d{2})(\d{2})\d{2}\s(.*)$"#
).matchingSemantics(.unicodeScalar)

/// [gnuLine]・[zipinfoLine] の1行（種類、サイズ、年、月、日、時、分、名前の順）から項目を作る。
private nonisolated func listedItem(_ m: Regex<AnyRegexOutput>.Match) -> ArchiveItem? {
  let n = (2...7).map { Int(regexGroup(m, $0)!)! }
  return item(regexGroup(m, 1)!, regexGroup(m, 8)!, n[0], localDateTime(n[1], n[2], n[3], n[4], n[5]))
}

/// 一覧の1行から項目を作る。[type] は ls -l の1文字目。名前の先頭の ./ と末尾の / は除き、リンクの先は除く。
private nonisolated func item(_ type: String, _ listed: String, _ size: Int, _ modified: Date) -> ArchiveItem? {
  var name = listed
  // シンボリックリンクは「名前 -> 先」、ハードリンクは「名前 link to 先」と出る。
  for arrow in (type == "l" ? [" -> "] : []) + (type == "h" ? [" link to "] : []) {
    if let at = name.range(of: arrow, options: .literal) {
      name = String(name[..<at.lowerBound])
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
    return nil
  }
  return ArchiveItem(path: name, raw: raw, isDir: isDir, size: size, modified: modified)
}
