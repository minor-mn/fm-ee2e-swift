import Foundation

/// Create a new Containerfile / Modify the Containerfile の小窓で決める、Containerfile の項目。
struct ContainerfileSettings: Equatable {
  enum Command: Equatable {
    /// CMD ["sleep", "infinity"]。シェルが既定のイメージでも、起動したまま止まらない。
    case keepRunning
    /// CMD を書かない（イメージの既定のまま）。
    case image
    /// CMD のあとに書く文字列（シェル形式でも JSON の配列でもよい）。
    case custom(String)
  }

  /// FROM の --platform（linux/arm64 など）。
  var platform = ""
  var image = ""
  var packages: [String] = []
  /// KEY=VALUE。TZ・LANG は下の欄で決めるので含めない。
  var environment: [String] = []
  /// ENV の TZ（Asia/Tokyo など）。
  var timezone = ""
  /// ENV の LANG の「.」より前（C、ja_JP など）と後（UTF-8 など）。
  var language = ""
  var charset = ""
  var workdir = ""
  /// 8080、53/udp など。
  var ports: [String] = []
  var command = Command.keepRunning
}

/// パッケージを入れる RUN の書き方。どれを使うかはイメージ名から決める。
enum PackageManager: String {
  case apt, apk, dnf, yum

  /// RHEL 系は、dnf のない古い版でも動き、新しい版では dnf の別名になっている yum を使う。
  /// イメージを選んでいないとき、CentOS 7 以下（取得先のリポジトリがもうない）のときは、パッケージを入れない（nil）。
  static func of(_ image: String) -> PackageManager? {
    let name = image.lowercased()
    if name.isEmpty || isOldCentOS(name) { return nil }
    if name.contains("alpine") { return .apk }
    if name.contains("fedora") { return .dnf }
    if ["rockylinux", "almalinux", "centos", "ubi", "amazonlinux", "oraclelinux"].contains(where: name.contains) { return .yum }
    return .apt
  }

  /// centos:7、centos:6.10、centos:centos7 など。タグのないもの（latest）は含めない。
  private static func isOldCentOS(_ name: String) -> Bool {
    let last = name.split(separator: "/").last.map(String.init) ?? name
    guard last.hasPrefix("centos:") else { return false }
    var tag = Substring(last.dropFirst("centos:".count))
    if tag.hasPrefix("centos") { tag = tag.dropFirst("centos".count) }
    return Int(tag.prefix { $0.isNumber }).map { $0 <= 7 } ?? false
  }

  /// RUN のあとに書く文字列。
  func install(_ packages: [String]) -> String {
    let list = packages.joined(separator: " ")
    return switch self {
    case .apt: "apt-get update && apt-get install -y --no-install-recommends \(list) && rm -rf /var/lib/apt/lists/*"
    case .apk: "apk add --no-cache \(list)"
    case .dnf: "dnf install -y \(list) && dnf clean all"
    case .yum: "yum install -y \(list) && yum clean all"
    }
  }

  /// LANG の [language]（ja_JP など）・[charset]（UTF-8 など）のロケールを使えるようにする RUN のあとに書く文字列。
  /// C・POSIX（どのイメージにもある）や、musl でロケールの仕組みが違う Alpine では要らないので nil。
  func locale(language: String, charset: String) -> String? {
    guard !language.isEmpty, !["C", "POSIX"].contains(language) else { return nil }
    let name = charset.isEmpty ? language : "\(language).\(charset)"
    let langpack = "glibc-langpack-" + (language.split(separator: "_").first.map(String.init) ?? language)
    return switch self {
    case .apt:
      "apt-get update && apt-get install -y --no-install-recommends locales && rm -rf /var/lib/apt/lists/* && localedef -i \(language)"
        + (charset.isEmpty ? "" : " -f \(charset)") + " \(name)"
    case .dnf, .yum: "\(rawValue) install -y \(langpack) && \(rawValue) clean all"
    case .apk: nil
    }
  }

  /// [locale] で書いた RUN か。
  static func isLocale(_ run: String) -> Bool {
    let patterns = [
      #"^apt-get update && apt-get install -y --no-install-recommends locales && rm -rf /var/lib/apt/lists/\* && localedef -i \S+( -f \S+)? \S+$"#,
      #"^(dnf|yum) install -y glibc-langpack-[A-Za-z]+ && (dnf|yum) clean all$"#,
    ]
    let text = run.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
  }

  /// [install] で書いた RUN なら、そのパッケージ。どの書き方とも違えば nil。
  static func packages(in run: String) -> [String]? {
    let words = run.split(whereSeparator: \.isWhitespace).map(String.init)
    for manager in [PackageManager.apt, .apk, .dnf, .yum] {
      let template = manager.install(["\u{0}"]).split(separator: " ").map(String.init)
      guard let slot = template.firstIndex(of: "\u{0}"), words.count >= template.count else { continue }
      let tail = template.count - slot - 1
      let count = words.count - template.count + 1
      guard Array(words.prefix(slot)) == Array(template.prefix(slot)), Array(words.suffix(tail)) == Array(template.suffix(tail)) else { continue }
      let found = Array(words[slot..<(slot + count)])
      if !found.contains(where: { $0.contains("&&") || $0.hasPrefix("-") }) { return found }
    }
    return nil
  }
}

/// Containerfile の中身。小窓で扱う行（最後のステージの FROM・パッケージの RUN・ENV・WORKDIR・EXPOSE・CMD）のうち、
/// 値を変えた行だけを書き換える。ほかの行（手で書いた RUN・COPY・コメント・空行・ほかのステージなど）と、変えていない行は元のまま残す。
struct Containerfile {
  enum Kind { case from, packages, locale, environment, workdir, expose, command }

  /// 継続行（末尾の \）をつないだ1つの命令。[lines] は元の行。
  struct Entry {
    var kind: Kind?
    var lines: [String]
    /// 命令のあとの引数（継続行は空白でつなぐ）。
    var arguments: String
  }

  private(set) var entries: [Entry] = []
  /// 最後の行のあとの改行の数（元の書き方のまま戻す）。
  private var trailingNewlines = 0

  init(_ text: String) {
    var current: [String] = []
    var instructions: [String] = []
    func finish() {
      guard !current.isEmpty else { return }
      let joined = current.map { line -> String in
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix("\\") ? String(trimmed.dropLast()) : trimmed
      }.joined(separator: " ")
      let words = joined.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
      let instruction = joined.hasPrefix("#") ? "" : (words.first ?? "").uppercased()
      entries.append(Entry(kind: nil, lines: current, arguments: words.count > 1 ? words[1].trimmingCharacters(in: .whitespaces) : ""))
      instructions.append(instruction)
      current = []
    }
    for line in text.components(separatedBy: "\n") {
      current.append(line)
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if !(trimmed.hasSuffix("\\") && !trimmed.hasPrefix("#")) { finish() }
    }
    finish()
    // 末尾の改行で増えた空行は数えておき、書き出すときに同じだけ戻す。
    while let last = entries.last, last.lines == [""] {
      entries.removeLast()
      instructions.removeLast()
      trailingNewlines += 1
    }
    // 最後のステージ（最後の FROM から下）の行だけを小窓で扱う。
    guard let from = instructions.lastIndex(of: "FROM") else { return }
    entries[from].kind = .from
    var lastWorkdir: Int?
    var lastCommand: Int?
    var packages: Int?
    var locale: Int?
    for index in entries.indices where index > from {
      let words = Self.words(entries[index].arguments)
      switch instructions[index] {
      case "RUN" where packages == nil && PackageManager.packages(in: entries[index].arguments) != nil:
        packages = index
        entries[index].kind = .packages
      case "RUN" where locale == nil && PackageManager.isLocale(entries[index].arguments):
        locale = index
        entries[index].kind = .locale
      case "ENV" where !words.isEmpty && words.allSatisfy(Self.isSimpleVariable):
        entries[index].kind = .environment
      case "EXPOSE" where !words.isEmpty && words.allSatisfy({ $0.range(of: #"^[0-9]+(/[A-Za-z]+)?$"#, options: .regularExpression) != nil }):
        entries[index].kind = .expose
      case "WORKDIR" where words.count == 1 && words[0].range(of: #"^[A-Za-z0-9_./:@+-]+$"#, options: .regularExpression) != nil:
        lastWorkdir = index
      case "CMD":
        lastCommand = index
      default:
        break
      }
    }
    if let lastWorkdir { entries[lastWorkdir].kind = .workdir }
    if let lastCommand { entries[lastCommand].kind = .command }
  }

  private static func isSimpleVariable(_ word: String) -> Bool { word.range(of: #"^[A-Za-z_][A-Za-z0-9_]*=[^"'\\$\s]*$"#, options: .regularExpression) != nil }

  private func first(_ kind: Kind) -> Entry? { entries.first { $0.kind == kind } }

  private static func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

  /// FROM の引数のうち、イメージの位置（--platform などを飛ばした最初の語）。
  private static func imageIndex(_ words: [String]) -> Int? { words.firstIndex { !$0.hasPrefix("--") } }

  private static let keepRunning = #"["sleep", "infinity"]"#

  /// 今の中身から読んだ小窓の項目。FROM がなければ空の設定。
  var settings: ContainerfileSettings {
    // CMD のない中身は「イメージのまま」。空の中身から作るときに、書く CMD を変えていないと見なさないようにする。
    var settings = ContainerfileSettings(command: .image)
    guard let from = first(.from) else { return settings }
    let fromWords = Self.words(from.arguments)
    settings.image = Self.imageIndex(fromWords).map { fromWords[$0] } ?? ""
    settings.platform = fromWords.first { $0.hasPrefix("--platform=") }.map { String($0.dropFirst("--platform=".count)) } ?? ""
    settings.packages = first(.packages).flatMap { PackageManager.packages(in: $0.arguments) } ?? []
    // TZ・LANG は専用の欄に分け、ほかを環境変数の欄に出す。
    for word in entries.filter({ $0.kind == .environment }).flatMap({ Self.words($0.arguments) }) {
      let value = String(word.drop { $0 != "=" }.dropFirst())
      switch word.prefix(while: { $0 != "=" }) {
      case "TZ": settings.timezone = value
      case "LANG":
        let parts = value.split(separator: ".", maxSplits: 1).map(String.init)
        settings.language = parts.first ?? ""
        settings.charset = parts.count > 1 ? parts[1] : ""
      default: settings.environment.append(word)
      }
    }
    settings.workdir = first(.workdir)?.arguments ?? ""
    settings.ports = entries.filter { $0.kind == .expose }.flatMap { Self.words($0.arguments) }
    if let command = first(.command)?.arguments {
      let compact = command.replacingOccurrences(of: " ", with: "")
      settings.command = compact == Self.keepRunning.replacingOccurrences(of: " ", with: "") ? .keepRunning : .custom(command)
    } else {
      settings.command = .image
    }
    return settings
  }

  /// [new] を書き込んだ中身。値を変えた項目の行だけを書き換え、行がなければ決まった位置に足し、空にした項目の行は消す。
  /// ENV・EXPOSE は行ごとに見て、消した値・変えた値を含む行だけを書き直し、新しい値は最後の行の下に1行足す。
  func text(_ new: ContainerfileSettings) -> String {
    let old = settings
    var entries = self.entries
    func entry(_ kind: Kind, _ instruction: String, _ arguments: String) -> Entry {
      Entry(kind: kind, lines: ["\(instruction) \(arguments)"], arguments: arguments)
    }
    func lastIndex(_ kinds: [Kind]) -> Int? { entries.lastIndex { $0.kind.map(kinds.contains) ?? false } }
    /// その項目の行がないときに足す位置。
    func insertion(_ kind: Kind) -> Int {
      switch kind {
      // FROM がなければ、先頭のコメント（# syntax= など）と空行のあとに書く。
      case .from: entries.firstIndex { !($0.lines.first ?? "").trimmingCharacters(in: .whitespaces).hasPrefix("#") && $0.lines != [""] } ?? entries.count
      // ENV はパッケージの RUN より前に置き、インストールにも効かせる（DEBIAN_FRONTEND など）。
      case .packages: (lastIndex([.from, .environment]) ?? -1) + 1
      case .environment: (lastIndex([.from, .environment]) ?? -1) + 1
      case .locale: (lastIndex([.from, .environment, .packages]) ?? -1) + 1
      case .workdir: (lastIndex([.from, .packages, .locale, .environment]) ?? -1) + 1
      case .expose: lastIndex([.expose]).map { $0 + 1 } ?? lastIndex([.command]) ?? entries.count
      case .command: entries.count
      }
    }
    /// 1行だけの項目を置き換える（nil なら消す）。行がなければ足す。
    func replace(_ kind: Kind, _ instruction: String, _ arguments: String?) {
      if let index = entries.firstIndex(where: { $0.kind == kind }) {
        if let arguments { entries[index] = entry(kind, instruction, arguments) } else { entries.remove(at: index) }
      } else if let arguments {
        entries.insert(entry(kind, instruction, arguments), at: insertion(kind))
      }
    }
    /// ENV・EXPOSE。[key] が同じ値を同じものとして、変わった行だけを書き直す。
    func update(_ kind: Kind, _ instruction: String, _ values: [String], key: (String) -> String) {
      let wanted = Dictionary(values.map { (key($0), $0) }, uniquingKeysWith: { _, last in last })
      var handled = Set<String>()
      var removed: [Int] = []
      for index in entries.indices where entries[index].kind == kind {
        var changed = false
        var kept: [String] = []
        for word in Self.words(entries[index].arguments) {
          let name = key(word)
          guard let value = wanted[name], !handled.contains(name) else { changed = true; continue }
          handled.insert(name)
          if value != word { changed = true }
          kept.append(value)
        }
        guard changed else { continue }
        if kept.isEmpty { removed.append(index) } else { entries[index] = entry(kind, instruction, kept.joined(separator: " ")) }
      }
      for index in removed.reversed() { entries.remove(at: index) }
      var added: [String] = []
      for value in values where !handled.contains(key(value)) {
        handled.insert(key(value))
        added.append(wanted[key(value)]!)
      }
      if !added.isEmpty { entries.insert(entry(kind, instruction, added.joined(separator: " ")), at: insertion(kind)) }
    }

    // FROM は、イメージか platform を変えたときだけ書き直す。AS などほかの語は残す。
    if new.image != old.image || new.platform != old.platform {
      let platform = new.platform.isEmpty ? [] : ["--platform=\(new.platform)"]
      if let index = entries.firstIndex(where: { $0.kind == .from }) {
        var words = Self.words(entries[index].arguments).filter { !$0.hasPrefix("--platform=") }
        if let at = Self.imageIndex(words) { words[at] = new.image } else { words.append(new.image) }
        entries[index] = entry(.from, "FROM", (platform + words).joined(separator: " "))
      } else {
        replace(.from, "FROM", (platform + [new.image]).joined(separator: " "))
      }
    }
    // 道具（apt・apk・dnf・yum）が変わるイメージにしたときも、パッケージの行を書き直す。道具のないイメージなら行を消す。
    let manager = PackageManager.of(new.image)
    let packages = manager == nil ? [] : new.packages
    if packages != old.packages || (!packages.isEmpty && manager != PackageManager.of(old.image)) {
      replace(.packages, "RUN", manager.flatMap { packages.isEmpty ? nil : $0.install(packages) })
    }
    /// ENV に書く KEY=VALUE（環境変数の欄・TZ・LANG）。
    func variables(_ settings: ContainerfileSettings) -> [String] {
      // 言語が空欄なら C にする（文字コードも空欄なら LANG は書かない）。
      let language = settings.language.isEmpty && !settings.charset.isEmpty ? "C" : settings.language
      let lang = [language, settings.charset].filter { !$0.isEmpty }.joined(separator: ".")
      return settings.environment + (settings.timezone.isEmpty ? [] : ["TZ=\(settings.timezone)"]) + (lang.isEmpty ? [] : ["LANG=\(lang)"])
    }
    if variables(new) != variables(old) {
      update(.environment, "ENV", variables(new)) { String($0.prefix { $0 != "=" }) }
    }
    // ロケールの行は、イメージ・言語・文字コードから決まる。決まる中身が変わったときだけ書き直す。
    func localeLine(_ settings: ContainerfileSettings) -> String? {
      let language = settings.language.isEmpty && !settings.charset.isEmpty ? "C" : settings.language
      return PackageManager.of(settings.image)?.locale(language: language, charset: settings.charset)
    }
    if localeLine(new) != localeLine(old) {
      replace(.locale, "RUN", localeLine(new))
    }
    if new.workdir != old.workdir {
      replace(.workdir, "WORKDIR", new.workdir.isEmpty ? nil : new.workdir)
    }
    if new.ports != old.ports {
      update(.expose, "EXPOSE", new.ports) { $0.lowercased() }
    }
    if new.command != old.command {
      let arguments: String? = switch new.command {
      case .keepRunning: Self.keepRunning
      case .image: nil
      case .custom(let text): text.isEmpty ? nil : text
      }
      replace(.command, "CMD", arguments)
    }
    // 新しく作るときは、最後に改行を1つ付ける。
    let newlines = self.entries.isEmpty && trailingNewlines <= 1 ? 1 : trailingNewlines
    return entries.flatMap(\.lines).joined(separator: "\n") + String(repeating: "\n", count: newlines)
  }
}
