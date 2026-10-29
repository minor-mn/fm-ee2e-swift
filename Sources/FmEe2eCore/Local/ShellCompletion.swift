import Darwin
import Foundation

/// Tab 補完の結果。[before] はカーソルより前の新しい文字列。補完しきれないときは [candidates] に候補を入れる。
nonisolated struct Completion: Sendable {
  init(_ before: String, _ candidates: [String] = []) {
    self.before = before
    self.candidates = candidates
  }

  let before: String
  let candidates: [String]
}

/// 補完の候補を探す場所（この Mac か、SSH の接続先か）。
protocol CompletionSource {
  /// PATH にある、[prefix] で始まるコマンドの名前。
  func commands(_ prefix: String) async throws -> Set<String>

  /// [dir]（入力したままの形。空なら今のフォルダー、~ はホーム、相対なら今のフォルダーから）にある項目の名前と、フォルダーか。
  /// 開けなければ空。
  func files(_ dir: String) async throws -> [String: Bool]
}

/// この Mac の [cwd] で補完する。
final class LocalCompletion: CompletionSource {
  init(_ cwd: String) {
    self.cwd = cwd
  }

  let cwd: String

  func commands(_ prefix: String) async throws -> Set<String> { localCommands(prefix) }

  func files(_ dir: String) async throws -> [String: Bool] { localFiles(dir, cwd) }
}

/// Dart の RegExp の \s に当たる空白か。
nonisolated func isRegExpSpace(_ c: Unicode.Scalar) -> Bool {
  switch c.value {
  case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
  default: false
  }
}

/// Dart の String.compareTo と同じ、UTF-16 の並び順。
nonisolated func codeUnitsBefore(_ a: String, _ b: String) -> Bool { a.utf16.lexicographicallyPrecedes(b.utf16) }

private nonisolated func startsWith(_ s: String, _ prefix: String) -> Bool {
  s.unicodeScalars.starts(with: prefix.unicodeScalars)
}

/// bash に近い Tab 補完。行頭（| ; & の後も）の単語は PATH のコマンド名、それ以外は今のフォルダーからのパス。
/// 候補が1つなら補完し（フォルダーは /、それ以外は空白を付ける）、複数なら共通部分まで補完する。
/// それ以上進めないときは候補を返す。候補がなければ nil。
/// 「.」で始まる項目は、入力が「.」で始まるときだけ候補にする。
func completeShellWord(_ before: String, _ source: any CompletionSource) async throws -> Completion? {
  let scalars = Array(before.unicodeScalars)
  let start = wordStart(scalars)
  let raw = Array(scalars[start...])
  let word = unescape(String(String.UnicodeScalarView(raw)))
  let headLast = scalars[..<start].last { !isRegExpSpace($0) }
  let isCommand = !word.unicodeScalars.contains("/") && (headLast == nil || "|;&(".unicodeScalars.contains(headLast!))

  let rawDir: String
  let prefix: String
  var names: [String: Bool] = [:]  // 名前 → フォルダーか
  if isCommand {
    rawDir = ""
    prefix = word
    for name in try await source.commands(prefix) {
      names[name] = false
    }
  } else {
    let slash = raw.lastIndex(of: "/") ?? -1
    rawDir = String(String.UnicodeScalarView(raw[..<(slash + 1)]))
    prefix = unescape(String(String.UnicodeScalarView(raw[(slash + 1)...])))
    for (name, isDir) in try await source.files(unescape(rawDir))
    where startsWith(name, prefix) && (prefix.hasPrefix(".") || !name.hasPrefix(".")) {
      names[name] = isDir
    }
  }
  if names.isEmpty {
    return nil
  }
  let sorted = names.keys.sorted(by: codeUnitsBefore)
  let completed: String
  if sorted.count == 1 {
    let name = sorted[0]
    completed = "\(escape(name))\(names[name]! ? "/" : " ")"
  } else {
    let common = commonPrefix(sorted)
    if common.unicodeScalars.count <= prefix.unicodeScalars.count {
      return Completion(before, sorted.map { names[$0]! ? "\($0)/" : $0 })
    }
    completed = escape(common)
  }
  return Completion(String(String.UnicodeScalarView(scalars[..<start])) + rawDir + completed)
}

/// カーソル前の最後の単語の開始位置。バックスラッシュでエスケープした空白は区切りにしない。
private nonisolated func wordStart(_ s: [Unicode.Scalar]) -> Int {
  var i = s.count - 1
  while i >= 0 {
    if " \t|;&()<>".unicodeScalars.contains(s[i]) && !(i > 0 && s[i - 1] == "\\") {
      return i + 1
    }
    i -= 1
  }
  return 0
}

private nonisolated func unescape(_ s: String) -> String {
  let scalars = Array(s.unicodeScalars)
  var out = String.UnicodeScalarView()
  var i = 0
  while i < scalars.count {
    // 「\」の次の1文字（改行の類を除く）をそのまま使う。
    if scalars[i] == "\\" && i + 1 < scalars.count && !"\n\r\u{2028}\u{2029}".unicodeScalars.contains(scalars[i + 1]) {
      out.append(scalars[i + 1])
      i += 2
    } else {
      out.append(scalars[i])
      i += 1
    }
  }
  return String(out)
}

private nonisolated func escape(_ s: String) -> String {
  var out = String.UnicodeScalarView()
  for c in s.unicodeScalars {
    if isRegExpSpace(c) || "\\'\"`$&|;<>()!*?[]{}#~".unicodeScalars.contains(c) {
      out.append("\\")
    }
    out.append(c)
  }
  return String(out)
}

private nonisolated func commonPrefix(_ names: [String]) -> String {
  var common = Array(names[0].unicodeScalars)
  for name in names.dropFirst() {
    let other = Array(name.unicodeScalars)
    var i = 0
    while i < common.count && i < other.count && common[i] == other[i] {
      i += 1
    }
    common = Array(common[..<i])
  }
  return String(String.UnicodeScalarView(common))
}

/// PATH にある、[prefix] で始まる実行可能ファイルの名前。
private nonisolated func localCommands(_ prefix: String) -> Set<String> {
  var result = Set<String>()
  for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":") {
    if dir.isEmpty {
      continue
    }
    // 読めないフォルダーは飛ばす。
    guard let entities = try? listDirectory(dir) else {
      continue
    }
    for entity in entities {
      let name = p.basename(entity)
      if startsWith(name, prefix) && !result.contains(name) {
        let stat = statPath(entity)
        if stat.type == .file && stat.mode & 0x49 != 0 {
          result.insert(name)
        }
      }
    }
  }
  return result
}

/// [dir]（~ はホーム、相対なら [cwd] から）にある項目。
private nonisolated func localFiles(_ dir: String, _ cwd: String) -> [String: Bool] {
  var path = dir.isEmpty ? "." : dir
  if path == "~" || path.hasPrefix("~/") {
    path = homeDir + path.dropFirst()
  }
  var result: [String: Bool] = [:]
  // 開けないフォルダーなら候補なし。
  guard let entities = try? listDirectory(p.join(cwd, path)) else {
    return result
  }
  for entity in entities {
    result[p.basename(entity)] = statPath(entity).type == .directory
  }
  return result
}
