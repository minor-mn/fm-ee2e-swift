import Foundation

/// 設定ファイル（~/.config/fm-ee2e/config.yml）。
///
/// ```yaml
/// right_tabs:
///   google_drive: on
///   git: on
///   ssh: on
///   icloud: on
///   local: on
/// ```
///
/// ファイルや項目がなければ on。
struct AppConfig {
  init(rightTabs: [RightMode] = RightMode.allCases) {
    self.rightTabs = rightTabs
  }

  /// 右の窓に出すタブ（Tab で切り替える順）。
  let rightTabs: [RightMode]

  static var file: String { p.join(homeDir, ".config", "fm-ee2e", "config.yml") }

  /// 設定ファイルでのタブの名前（書く順）。
  private static let tabNames: [(String, RightMode)] = [
    ("google_drive", .drive),
    ("git", .git),
    ("ssh", .ssh),
    ("icloud", .icloud),
    ("local", .local),
  ]

  /// [file] を読む。なければ既定の設定。形式が違えば [ConfigFormatError]。
  static func load() async throws -> AppConfig {
    guard let data = FileManager.default.contents(atPath: file) else {
      return AppConfig()
    }
    guard let yaml = try parseYaml(String(decoding: data, as: UTF8.self)) else {
      return AppConfig()
    }
    guard case .map(let root) = yaml else {
      throw ConfigFormatError("right_tabs などの項目を書いてください。")
    }
    guard let tabs = root.first(where: { $0.0 == "right_tabs" })?.1, tabs != .null else {
      return AppConfig()
    }
    guard case .map(let entries) = tabs else {
      throw ConfigFormatError("right_tabs には、タブごとに on か off を書いてください。")
    }
    var off = Set<RightMode>()
    for (key, value) in entries {
      guard let mode = tabNames.first(where: { $0.0 == key })?.1 else {
        throw ConfigFormatError("right_tabs の「\(key)」は使えません。\(tabNames.map(\.0).joined(separator: "・")) のどれかです。")
      }
      if !(try isOn(value)) {
        off.insert(mode)
      }
    }
    return AppConfig(rightTabs: RightMode.allCases.filter { !off.contains($0) })
  }

  /// on か off か。YAML 1.2 では on・off は文字列なので、true・false と合わせて受け付ける。
  private static func isOn(_ value: YamlValue) throws -> Bool {
    do {
      switch value {
      case .scalar("true"), .scalar("True"), .scalar("TRUE"), .scalar("on"): return true
      case .scalar("false"), .scalar("False"), .scalar("FALSE"), .scalar("off"): return false
      case .scalar(let s), .quoted(let s): throw ConfigFormatError("right_tabs の値は on か off です（「\(s)」）。")
      case .null: throw ConfigFormatError("right_tabs の値は on か off です（「null」）。")
      case .map: throw ConfigFormatError("right_tabs の値は on か off です。")
      }
    }
  }
}

/// 設定ファイルの形式の誤り（Dart の FormatException）。
struct ConfigFormatError: Error, CustomStringConvertible {
  init(_ message: String) {
    self.message = message
  }

  let message: String

  var description: String { message }
}

/// 設定ファイルに使う YAML の一部（字下げした対応付け・スカラー・コメント）。
indirect enum YamlValue: Equatable {
  case null
  case scalar(String)
  case quoted(String)
  case map([(String, YamlValue)])

  static func == (a: YamlValue, b: YamlValue) -> Bool {
    switch (a, b) {
    case (.null, .null): true
    case let (.scalar(x), .scalar(y)), let (.quoted(x), .quoted(y)): x == y
    case let (.map(x), .map(y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    default: false
    }
  }
}

/// [text] を読む。空（コメントだけ）なら nil。
func parseYaml(_ text: String) throws -> YamlValue? {
  // 字下げと、コメントを除いた中身の行。
  var lines: [(number: Int, indent: Int, text: String)] = []
  for (i, raw) in text.components(separatedBy: "\n").enumerated() {
    let line = stripComment(raw.hasSuffix("\r") ? String(raw.dropLast()) : raw)
    let content = line.trimmingCharacters(in: .whitespaces)
    if content.isEmpty || content == "---" {
      continue
    }
    if line.hasPrefix("\t") {
      throw ConfigFormatError("\(i + 1)行目: 字下げにタブは使えません。")
    }
    lines.append((i + 1, line.prefix { $0 == " " }.count, content))
  }
  if lines.isEmpty {
    return nil
  }
  var index = 0
  if !lines[0].text.contains(":") {
    // 対応付けでなければ、1つのスカラー。
    if lines.count > 1 {
      throw ConfigFormatError("\(lines[1].number)行目: 読めません。")
    }
    return scalar(lines[0].text)
  }
  let value = try parseMap(lines, &index, indent: lines[0].indent)
  if index < lines.count {
    throw ConfigFormatError("\(lines[index].number)行目: 字下げが合いません。")
  }
  return value
}

private func parseMap(_ lines: [(number: Int, indent: Int, text: String)], _ index: inout Int, indent: Int) throws -> YamlValue {
  var entries: [(String, YamlValue)] = []
  while index < lines.count && lines[index].indent == indent {
    let line = lines[index]
    guard let colon = keyEnd(line.text) else {
      throw ConfigFormatError("\(line.number)行目: 「名前: 値」の形で書いてください。")
    }
    let key = unquote(String(line.text[..<colon]).trimmingCharacters(in: .whitespaces))
    let rest = String(line.text[line.text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    if entries.contains(where: { $0.0 == key }) {
      throw ConfigFormatError("\(line.number)行目: 「\(key)」が2回あります。")
    }
    index += 1
    if !rest.isEmpty {
      entries.append((key, scalar(rest)))
    } else if index < lines.count && lines[index].indent > indent {
      entries.append((key, try parseMap(lines, &index, indent: lines[index].indent)))
    } else {
      entries.append((key, .null))
    }
  }
  if index < lines.count && lines[index].indent > indent {
    throw ConfigFormatError("\(lines[index].number)行目: 字下げが合いません。")
  }
  return .map(entries)
}

/// 「名前: 」の「:」の位置（引用符の中は除く）。
private func keyEnd(_ text: String) -> String.Index? {
  var quote: Character?
  var i = text.startIndex
  while i < text.endIndex {
    let c = text[i]
    if let q = quote {
      if c == q { quote = nil }
    } else if c == "\"" || c == "'" {
      quote = c
    } else if c == ":" {
      let next = text.index(after: i)
      if next == text.endIndex || text[next] == " " {
        return i
      }
    }
    i = text.index(after: i)
  }
  return nil
}

/// 「 #」から後ろを除く（引用符の中は除く）。
private func stripComment(_ line: String) -> String {
  var quote: Character?
  var previous: Character = " "
  var i = line.startIndex
  while i < line.endIndex {
    let c = line[i]
    if let q = quote {
      if c == q { quote = nil }
    } else if c == "\"" || c == "'" {
      quote = c
    } else if c == "#" && (previous == " " || i == line.startIndex) {
      return String(line[..<i])
    }
    previous = c
    i = line.index(after: i)
  }
  return line
}

private func unquote(_ s: String) -> String {
  if s.count >= 2, let first = s.first, first == "\"" || first == "'", s.last == first {
    return String(s.dropFirst().dropLast())
  }
  return s
}

private func scalar(_ s: String) -> YamlValue {
  if s.count >= 2, let first = s.first, first == "\"" || first == "'", s.last == first {
    return .quoted(String(s.dropFirst().dropLast()))
  }
  return s == "~" || s == "null" || s == "Null" || s == "NULL" ? .null : .scalar(s)
}
