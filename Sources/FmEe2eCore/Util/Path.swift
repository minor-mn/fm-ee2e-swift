import Foundation

/// パスの操作（Dart の package:path の POSIX 版と同じ動き）。
/// [current] は相対パスの基準（nil ならプロセスの作業フォルダー）。
nonisolated struct PathContext: Sendable {
  init(current: String? = nil) {
    fixedCurrent = current
  }

  private let fixedCurrent: String?

  /// ローカル（作業フォルダーが基準）。
  static let local = PathContext()

  /// SSH の接続先など、基準のないもの（「/」を基準にする）。
  static let posix = PathContext(current: "/")

  var separator: String { "/" }

  var current: String { fixedCurrent ?? FileManager.default.currentDirectoryPath }

  func isAbsolute(_ path: String) -> Bool { path.hasPrefix("/") }

  /// 空の部分は無視し、絶対パスの部分があればそこからやり直す。
  func join(_ parts: String...) -> String { join(parts) }

  func join(_ parts: [String]) -> String {
    var out = ""
    for part in parts where !part.isEmpty {
      if isAbsolute(part) || out.isEmpty {
        out = part
      } else if out.hasSuffix("/") {
        out += part
      } else {
        out += "/" + part
      }
    }
    return out
  }

  /// 「/」で分ける（結合文字が「/」に付いても分けられるよう、スカラーで見る）。
  private func components(_ path: String) -> [String] {
    path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: true).map { String(String.UnicodeScalarView($0)) }
  }

  /// 最後の「/」の位置（スカラーで見る）。
  private func lastSlash(_ s: String) -> String.Index? {
    s.unicodeScalars.lastIndex(of: "/")
  }

  /// 末尾の「/」を除く（「/」だけなら残す）。
  private func trimTrailing(_ path: String) -> String {
    var s = path
    while s.count > 1 && s.hasSuffix("/") {
      s.removeLast()
    }
    return s
  }

  func basename(_ path: String) -> String {
    let s = trimTrailing(path)
    if s == "/" {
      return "/"
    }
    if let slash = lastSlash(s) {
      return String(s.unicodeScalars[s.unicodeScalars.index(after: slash)...])
    }
    return s
  }

  func dirname(_ path: String) -> String {
    let s = trimTrailing(path)
    if s == "/" {
      return "/"
    }
    guard let slash = lastSlash(s) else {
      return "."
    }
    var dir = String(s.unicodeScalars[..<slash])
    while dir.hasSuffix("/") {
      dir.removeLast()
    }
    return dir.isEmpty ? "/" : dir
  }

  /// 拡張子（「.」を含む）。先頭の「.」（隠しファイル）は拡張子にしない。
  func `extension`(_ path: String) -> String {
    let name = basename(path)
    guard let dot = name.unicodeScalars.lastIndex(of: "."), dot != name.startIndex else {
      return ""
    }
    return String(name.unicodeScalars[dot...])
  }

  func withoutExtension(_ path: String) -> String {
    let ext = `extension`(path)
    if ext.isEmpty {
      return path
    }
    let s = trimTrailing(path)
    return String(String.UnicodeScalarView(s.unicodeScalars.dropLast(ext.unicodeScalars.count)))
  }

  /// 「/a/b」は ["/", "a", "b"]。
  func split(_ path: String) -> [String] {
    let parts = components(path)
    return isAbsolute(path) ? ["/"] + parts : parts
  }

  /// 「.」「..」と重なった「/」をまとめる。
  func normalize(_ path: String) -> String {
    let absolute = isAbsolute(path)
    var parts: [String] = []
    for part in components(path) {
      if part == "." {
        continue
      }
      if part == ".." {
        if let last = parts.last, last != ".." {
          parts.removeLast()
        } else if !absolute {
          parts.append("..")
        }
        continue
      }
      parts.append(part)
    }
    let joined = parts.joined(separator: "/")
    if absolute {
      return "/" + joined
    }
    return joined.isEmpty ? "." : joined
  }

  func absolute(_ path: String) -> String { isAbsolute(path) ? path : join(current, path) }

  /// [from]（既定は [current]）から見た [path] の相対パス。
  func relative(_ path: String, from: String? = nil) -> String {
    let target = split(normalize(absolute(path)))
    let base = split(normalize(absolute(from ?? current)))
    var i = 0
    while i < target.count && i < base.count && target[i] == base[i] {
      i += 1
    }
    let parts = Array(repeating: "..", count: base.count - i) + target[i...]
    return parts.isEmpty ? "." : parts.joined(separator: "/")
  }

  /// [child] が [parent] の中にあるか（同じパスは含まない）。
  func isWithin(_ parent: String, _ child: String) -> Bool {
    let p = split(normalize(absolute(parent)))
    let c = split(normalize(absolute(child)))
    return c.count > p.count && Array(c[0..<p.count]) == p
  }

  func equals(_ a: String, _ b: String) -> Bool {
    normalize(absolute(a)) == normalize(absolute(b))
  }
}

/// ローカルのパスの操作（Dart の `p.`）。
nonisolated let p = PathContext.local
