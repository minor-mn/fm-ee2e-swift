import Foundation

/// 枠の中で動くエディタ（uim）どうしで共有するレジスタ。ローカルでも SSH の先（2段目も）でも、
/// ヤンクした内容を OSC 7520 でここに置き、貼り付けるときにここから読む（[ShellTerminal] が扱う）。
/// Mac のクリップボードとは別で、アプリを終えると消える。
///
/// - 書き込み: `ESC ] 7520 ; set ; line|char ; Base64 BEL`（ST で終えてもよい）
/// - 読み出し: `ESC ] 7520 ; get BEL` に、`ESC ] 7520 ; line|char ; Base64 BEL` を返す。
///   空なら `ESC ] 7520 ; empty BEL` を返す。
enum SharedRegister {
  struct Content: Equatable {
    /// 行単位（yy などでヤンクした）か、文字単位か。
    let linewise: Bool
    let data: Data
  }

  /// 最後にヤンクされた内容。
  static var content: Content?

  /// OSC の番号。
  static let osc = "7520"

  /// 中身（Base64）を含めた OSC の文字数の上限。ほかの OSC は 4096 文字まで。
  static let limit = 16 << 20

  /// `;` で分けた OSC 7520 の中身を扱い、プログラムへ返す応答があれば返す。形の合わないものは無視する。
  static func handle(_ parts: [Substring]) -> String? {
    let command = parts.count > 1 ? parts[1] : ""
    if command == "set" && parts.count == 4 && (parts[2] == "line" || parts[2] == "char"),
      let data = Data(base64Encoded: String(parts[3]))
    {
      content = Content(linewise: parts[2] == "line", data: data)
    } else if command == "get" && parts.count == 2 {
      let head = "\u{1b}]\(osc);"
      guard let content else { return head + "empty\u{07}" }
      return head + (content.linewise ? "line;" : "char;") + content.data.base64EncodedString() + "\u{07}"
    }
    return nil
  }
}
