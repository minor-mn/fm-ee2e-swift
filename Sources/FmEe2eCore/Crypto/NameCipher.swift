import CryptoKit
import Foundation

/// Drive上のファイル名・フォルダー名の暗号化（v1）。
///
/// - ファイルは拡張子（最後の「.」以降。先頭の「.」は拡張子とみなさない）を平文のまま残し、その前を暗号化する。
///   フォルダーは名前全体を暗号化する。
/// - 名前用の鍵 = HKDF-SHA256(鍵, ソルトなし, "fm-ee2e v1 name key")
/// - 暗号化部分 = Base64url（パディングなし）で [版(1) | nonce(12) | 暗号文 | タグ(16)]
/// - AAD = "file:" + 拡張子 または "dir"。拡張子の書き換えやファイル・フォルダーの取り違えを検出する。
nonisolated struct NameCipher: Sendable {
  init(_ key: Data) {
    nameKey = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: key),
      salt: Data(),
      info: Self.info,
      outputByteCount: 32
    )
  }

  static let version: UInt8 = 1
  private static let info = Data("fm-ee2e v1 name key".utf8)

  private let nameKey: SymmetricKey

  /// 名前を最後の「.」で分ける。UTF-8 のバイト列で分けるので、元の名前（NFD など）をそのまま保つ。
  private static func split(_ name: String) -> (stem: String, ext: String) {
    let bytes = Array(name.utf8)
    guard let dot = bytes.lastIndex(of: UInt8(ascii: ".")), dot > 0 else {
      return (name, "")
    }
    return (String(decoding: bytes[..<dot], as: UTF8.self), String(decoding: bytes[dot...], as: UTF8.self))
  }

  private static func aad(_ isFolder: Bool, _ ext: String) -> Data { Data((isFolder ? "dir" : "file:\(ext)").utf8) }

  func encrypt(_ name: String, isFolder: Bool) -> String {
    let (stem, ext) = isFolder ? (name, "") : Self.split(name)
    // 鍵は32バイトなので失敗しない。
    let box = try! AES.GCM.seal(Data(stem.utf8), using: nameKey, authenticating: Self.aad(isFolder, ext))
    let bytes = Data([Self.version]) + Data(box.nonce) + box.ciphertext + box.tag
    let encoded = bytes.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "\(encoded)\(ext)"
  }

  /// 復号した名前。このアプリ・この鍵で暗号化した名前でなければ nil。
  func decrypt(_ name: String, isFolder: Bool) -> String? {
    let (encoded, ext) = isFolder ? (name, "") : Self.split(name)
    guard let decoded = decodeBase64(encoded, requirePadding: false) else {
      return nil
    }
    let bytes = [UInt8](decoded)
    if bytes.count < 1 + 12 + 16 || bytes[0] != Self.version {
      return nil
    }
    do {
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: bytes[1..<13]),
        ciphertext: bytes[13..<(bytes.count - 16)],
        tag: bytes[(bytes.count - 16)...]
      )
      let stem = try AES.GCM.open(box, using: nameKey, authenticating: Self.aad(isFolder, ext))
      guard let text = String(validating: stem, as: UTF8.self) else {
        return nil
      }
      return "\(text)\(ext)"
    } catch {
      return nil
    }
  }
}

/// Dart の base64.decode と同じく Base64 を読む。標準・URL 用のどちらの文字も受け付け、余りのビットが0でないものは不正とする。
/// [requirePadding] が false なら、パディングのないものも受け付ける（Dart の base64Url.normalize を通してから読むのと同じ）。
/// 読めなければ nil。
nonisolated func decodeBase64(_ text: String, requirePadding: Bool) -> Data? {
  var values: [UInt8] = []
  var padding = 0
  for byte in text.utf8 {
    let value: UInt8
    switch byte {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"): value = byte - UInt8(ascii: "A")
    case UInt8(ascii: "a")...UInt8(ascii: "z"): value = byte - UInt8(ascii: "a") + 26
    case UInt8(ascii: "0")...UInt8(ascii: "9"): value = byte - UInt8(ascii: "0") + 52
    case UInt8(ascii: "+"), UInt8(ascii: "-"): value = 62
    case UInt8(ascii: "/"), UInt8(ascii: "_"): value = 63
    case UInt8(ascii: "="):
      padding += 1
      continue
    default:
      return nil
    }
    // パディングのあとに文字が続くものは不正。
    if padding > 0 {
      return nil
    }
    values.append(value)
  }
  let rest = values.count % 4
  if rest == 1 || padding > 2 {
    return nil
  }
  if padding > 0 || requirePadding {
    // パディングがあるなら、ちょうど4文字の倍数になっていること。
    if (values.count + padding) % 4 != 0 {
      return nil
    }
  }
  var out = Data(capacity: values.count * 3 / 4)
  var index = 0
  while index + 4 <= values.count {
    let v = values[index..<index + 4].reduce(UInt32(0)) { $0 << 6 | UInt32($1) }
    out.append(contentsOf: [UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    index += 4
  }
  if rest == 2 {
    let v = UInt32(values[index]) << 6 | UInt32(values[index + 1])
    if v & 0xf != 0 {
      return nil
    }
    out.append(UInt8(v >> 4))
  } else if rest == 3 {
    let v = UInt32(values[index]) << 12 | UInt32(values[index + 1]) << 6 | UInt32(values[index + 2])
    if v & 0x3 != 0 {
      return nil
    }
    out.append(contentsOf: [UInt8(v >> 10 & 0xff), UInt8(v >> 2 & 0xff)])
  }
  return out
}
