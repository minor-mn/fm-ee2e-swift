import Foundation

/// 画面に出す文言。~/.config/fm-ee2e/languages/<設定の language>.json5 から読む（入れ子の名前を「.」でつないだもの → 文言）。
enum Strings {
  /// 言葉 [language] の文言のファイル。
  static func file(_ language: String) -> String { p.join(homeDir, ".config", "fm-ee2e", "languages", "\(language).json5") }

  /// 読んだ文言。読む前や読めなかったときは空（[tr] は名前をそのまま返す）。
  nonisolated(unsafe) static var table: [String: String] = [:]

  /// 文言のファイルの中身 [data] を読む。形式が違えば [ConfigFormatError]。
  /// 文字列の配列は、改行でつないだ1つの文言にする（ヘルプのような長い文言）。
  static func parse(_ data: Data) throws -> [String: String] {
    let json: Any
    do {
      json = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
    } catch {
      let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
      throw ConfigFormatError("JSON として読めません。" + (detail.map { "（\($0)）" } ?? ""))
    }
    guard let root = json as? [String: Any] else {
      throw ConfigFormatError("{ name: \"文言\", … } の形で書いてください。")
    }
    var result: [String: String] = [:]
    func add(_ value: Any, _ key: String) throws {
      switch value {
      case let text as String:
        result[key] = text
      case let lines as [Any]:
        result[key] = try lines.map { line in
          guard let line = line as? String else {
            throw ConfigFormatError("\(key) の配列には文字列だけを書けます。")
          }
          return line
        }.joined(separator: "\n")
      case let block as [String: Any]:
        for (name, child) in block {
          try add(child, key.isEmpty ? name : "\(key).\(name)")
        }
      default:
        throw ConfigFormatError("\(key) は文字列か、文字列の配列で書いてください。")
      }
    }
    try add(root, "")
    return result
  }

  /// 言葉 [language] の文言のファイルを読んで [table] にする。読めなければ、その理由を返す（[table] は変えない）。
  @discardableResult
  static func load(_ language: String) -> String? {
    let file = file(language)
    guard let data = FileManager.default.contents(atPath: file) else {
      // 文言のファイルがないので、この文だけはここに書く。
      return "\(file) がありません。リポジトリの languages フォルダーを ~/.config/fm-ee2e/ にコピーしてください。"
    }
    do {
      table = try parse(data)
      return nil
    } catch {
      return "\(file) を読み込めません。\n\(errorMessage(error))"
    }
  }
}

/// 文言 [key]（languages/ja.json5 の、入れ子の名前を「.」でつないだもの）。文言の中の {name} は [args] の name の値にする。
/// 文言がなければ [key] をそのまま返す。
nonisolated func tr(_ key: String, _ args: [String: Any] = [:]) -> String {
  guard var text = Strings.table[key] else {
    return key
  }
  for (name, value) in args {
    text = text.replacingOccurrences(of: "{\(name)}", with: "\(value)")
  }
  return text
}
