import Foundation

/// [value]（JSONSerialization で読める形の辞書・配列・文字列・数・真偽値・NSNull）を JSON5 の文字列にする。
/// 名前に使える文字だけのキーはクオートしない。要素はいつも1行に1つで、末尾にもカンマを付ける。キーは名前順。
func json5Text(_ value: Any) -> String { json5Text(value, indent: "") + "\n" }

private func json5Text(_ value: Any, indent: String) -> String {
  let inner = indent + "  "
  switch value {
  case let map as [String: Any]:
    if map.isEmpty { return "{}" }
    let lines = map.keys.sorted().map { key in "\(inner)\(json5Key(key)): \(json5Text(map[key]!, indent: inner)),\n" }
    return "{\n" + lines.joined() + indent + "}"
  case let list as [Any]:
    if list.isEmpty { return "[]" }
    return "[\n" + list.map { "\(inner)\(json5Text($0, indent: inner)),\n" }.joined() + indent + "]"
  case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
    return number.boolValue ? "true" : "false"
  case is NSNull:
    return "null"
  default:
    // 文字列と数は JSON と同じ書き方（エスケープも JSONSerialization に任せる）。
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("null".utf8)
    return String(decoding: data, as: UTF8.self)
  }
}

private func json5Key(_ key: String) -> String {
  key.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil ? key : json5Text(key, indent: "")
}
