import CryptoKit
import Foundation
import Security

/// AES-256-GCM（nonce 12バイト、タグ16バイト）。暗号文の後ろにタグを付けた形で扱う。
nonisolated protocol Aead: Sendable {
  func seal(_ key: Data, _ nonce: Data, _ plain: Data, _ aad: Data) throws -> Data

  /// タグが一致しなければ [AuthenticationException]。
  func open(_ key: Data, _ nonce: Data, _ sealed: Data, _ aad: Data) throws -> Data
}

nonisolated struct AuthenticationException: Error, CustomStringConvertible {
  init() {}

  var description: String { "AuthenticationException" }
}

/// CryptoKit の AES-GCM（Dart 版の OpenSSL の FFI の代わり）。
nonisolated struct CryptoKitAead: Aead {
  static let tagLength = 16

  /// Dart 版の OpenSslAead.load() と同じ形。CryptoKit は常に使えるので失敗しない。
  static func load() -> CryptoKitAead { CryptoKitAead() }

  func seal(_ key: Data, _ nonce: Data, _ plain: Data, _ aad: Data) throws -> Data {
    let box = try AES.GCM.seal(plain, using: Self.symmetricKey(key, nonce), nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
    return box.ciphertext + box.tag
  }

  func open(_ key: Data, _ nonce: Data, _ sealed: Data, _ aad: Data) throws -> Data {
    if sealed.count < Self.tagLength {
      throw AuthenticationException()
    }
    let symmetric = Self.symmetricKey(key, nonce)
    let cipherLength = sealed.count - Self.tagLength
    let start = sealed.startIndex
    do {
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: nonce),
        ciphertext: sealed[start..<start + cipherLength],
        tag: sealed[(start + cipherLength)...]
      )
      return try AES.GCM.open(box, using: symmetric, authenticating: aad)
    } catch CryptoKitError.authenticationFailure {
      throw AuthenticationException()
    }
  }

  private static func symmetricKey(_ key: Data, _ nonce: Data) -> SymmetricKey {
    precondition(key.count == 32 && nonce.count == 12, "鍵は32バイト、nonceは12バイトである必要があります。")
    return SymmetricKey(data: key)
  }
}

/// 暗号として安全な乱数のバイト列。
nonisolated func randomBytes(_ count: Int) -> Data {
  var bytes = Data(count: count)
  let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
  precondition(status == errSecSuccess, "乱数を作れません。")
  return bytes
}
