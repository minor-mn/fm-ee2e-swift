import CryptoKit
import Foundation

/// Drive 上の名前の置き方。
///
/// 名前は [NameCipher] で暗号化して置く。暗号化した名前が長すぎる（[maxLength] を超える）ものは、
/// 短い名前の本体と、暗号化した名前を中身に書いた隠しファイル（名前ファイル）の組にする。
///
/// - 本体の名前 = 暗号化した名前の SHA-256 の Base64url の先頭 [hashLength] 文字（+ 平文の拡張子）。
///   拡張子を付けると長すぎるときは付けない。
/// - 名前ファイル = 「.」+ 本体の名前の最初の「.」より前 + [nameFileSuffix]。同じフォルダーに置く。
/// - 名前ファイルは一覧に出さない（隠しファイルを表示していても）。
struct DriveNames {
  init(_ cipher: NameCipher) {
    self.cipher = cipher
  }

  let cipher: NameCipher

  static let nameFileSuffix = ".fm-ee2e-long-name"

  /// 暗号化した名前をそのまま使う長さの上限（文字数。暗号化した部分は ASCII だけ）。
  /// ファイルシステムの上限は255文字だが、Drive が衝突時に「 (1)」などを付ける分を空けておく。
  static let maxLength = 220

  static let hashLength = 32

  /// [name] が名前ファイルか。
  static func isNameFile(_ name: String) -> Bool { name.hasPrefix(".") && name.hasSuffix(nameFileSuffix) }

  /// 本体 [body] の名前ファイルの名前。本体の名前が「.」で始まる（暗号化した名前でない）なら nil。
  static func nameFile(of body: String) -> String? {
    let stem = body.prefix { $0 != "." }
    return stem.isEmpty ? nil : ".\(stem)\(nameFileSuffix)"
  }

  /// 本体 [path] の名前ファイルのパス。
  static func nameFilePath(of path: String) -> String? {
    nameFile(of: p.basename(path)).map { p.join(p.dirname(path), $0) }
  }

  /// 暗号化した名前 [encrypted] から作る本体の名前の、拡張子の前まで。
  private static func hash(_ encrypted: String) -> String {
    let digest = Data(SHA256.hash(data: Data(encrypted.utf8)))
    let encoded = digest.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return String(encoded.prefix(hashLength))
  }

  /// [name] を置くときの本体の名前と、長すぎるときは名前ファイルに書く暗号化した名前。
  func layout(_ name: String, isFolder: Bool) -> (body: String, longName: String?) {
    let encrypted = cipher.encrypt(name, isFolder: isFolder)
    // 平文の拡張子には ASCII 以外も入りうるので、多めに数える UTF-16 で数える。
    if encrypted.utf16.count <= Self.maxLength {
      return (encrypted, nil)
    }
    // 暗号化した部分（Base64url）に「.」はないので、最初の「.」から後ろが平文の拡張子。
    let ext = encrypted.firstIndex(of: ".").map { String(encrypted[$0...]) } ?? ""
    let hash = Self.hash(encrypted)
    let body = hash.utf16.count + ext.utf16.count <= Self.maxLength ? hash + ext : hash
    return (body, encrypted)
  }

  /// 一覧に出す名前。このアプリ・この鍵で暗号化した名前でなければ、そのまま。
  /// [siblings] はフォルダー [dir] の中の名前（一覧を読んだとき）。渡せば名前ファイルがあるかをそこで確かめる。
  func shown(_ dir: String, _ raw: String, isFolder: Bool, siblings: Set<String>? = nil) -> String {
    if let plain = cipher.decrypt(raw, isFolder: isFolder) {
      return plain
    }
    guard let nameFile = Self.nameFile(of: raw), siblings?.contains(nameFile) ?? true,
      let data = FileManager.default.contents(atPath: p.join(dir, nameFile)),
      let encrypted = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
      // 別の本体の名前ファイルを取り違えないよう、本体の名前が中身から作ったものかを確かめる。
      raw.prefix(while: { $0 != "." }) == Self.hash(encrypted),
      let plain = cipher.decrypt(encrypted, isFolder: isFolder)
    else {
      return raw
    }
    return plain
  }

  /// フォルダー [dir] の中に [name] を置く。置くパスを決め、[put] でそこに本体を置いてもらう。置いたパスを返す。
  /// 名前ファイルが要るときは先に書く（本体だけが残って名前が分からなくなることがないように）。
  /// [put] が失敗したら名前ファイルを消す。
  @discardableResult
  func place(_ dir: String, _ name: String, isFolder: Bool, _ put: (String) async throws -> Void) async throws -> String {
    let (body, longName) = layout(name, isFolder: isFolder)
    let path = p.join(dir, body)
    guard let longName, let nameFile = Self.nameFilePath(of: path) else {
      try await put(path)
      return path
    }
    try Data(longName.utf8).write(to: URL(fileURLWithPath: nameFile))
    do {
      try await put(path)
    } catch {
      try? FileManager.default.removeItem(atPath: nameFile)
      throw error
    }
    return path
  }

  /// 本体 [path] の名前ファイルが今あれば、そのパス。
  static func existingNameFile(of path: String) -> String? {
    guard let nameFile = nameFilePath(of: path), lstatPath(nameFile).type != .notFound else {
      return nil
    }
    return nameFile
  }
}
