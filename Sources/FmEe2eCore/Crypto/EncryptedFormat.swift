import CryptoKit
import Darwin
import Foundation

/// 暗号化ファイルの形式（v1）。
///
/// ヘッダー（52バイト）:
/// - 0..5   マジック "FMEE2E"
/// - 6      版（1）
/// - 7      予約（0）
/// - 8..15  鍵ID（SHA-256("fm-ee2e key id v1" || 鍵) の先頭8バイト）
/// - 16..19 平文チャンク長（ビッグエンディアン）
/// - 20..51 ソルト（ファイルごとの乱数）
///
/// 本体はチャンクの並び。各チャンクは「暗号文 + タグ16バイト」。
/// - ファイル鍵 = HKDF-SHA256(鍵, ソルト, "fm-ee2e v1 file key")
/// - nonce（12バイト）= 0..10 チャンク番号（ビッグエンディアン）、11 終端なら1・それ以外0
/// - AAD = ヘッダー全体
/// 最後のチャンク以外はすべて平文チャンク長ちょうど。空ファイルは長さ0の終端チャンク1つ。
nonisolated struct EncryptedFormat: Sendable {
  init(_ aead: any Aead, chunkSize: Int = defaultChunkSize) {
    precondition(chunkSize > 0 && chunkSize <= Self.maxChunkSize, "chunkSize が不正です（\(chunkSize)）。")
    self.aead = aead
    self.chunkSize = chunkSize
  }

  static let magic: [UInt8] = [0x46, 0x4d, 0x45, 0x45, 0x32, 0x45] // "FMEE2E"
  static let version: UInt8 = 1
  static let headerLength = 52
  static let tagLength = 16
  static let defaultChunkSize = 1024 * 1024
  static let maxChunkSize = 16 * 1024 * 1024

  private static let keyIdLabel = Data("fm-ee2e key id v1".utf8)
  private static let fileKeyInfo = Data("fm-ee2e v1 file key".utf8)

  let aead: any Aead
  let chunkSize: Int

  static func keyId(_ key: Data) -> Data {
    Data(SHA256.hash(data: keyIdLabel + key).prefix(8))
  }

  /// 平文の長さから暗号化後の長さを求める。
  func encryptedLength(_ plainLength: Int) -> Int {
    let chunks = plainLength == 0 ? 1 : (plainLength + chunkSize - 1) / chunkSize
    return Self.headerLength + plainLength + chunks * Self.tagLength
  }

  /// 先頭バイトが暗号化ファイルのマジックかどうか。
  static func hasMagic(_ bytes: Data) -> Bool {
    bytes.count >= magic.count && bytes.prefix(magic.count).elementsEqual(magic)
  }

  /// [read] から読んだ平文を暗号化して [write] に渡す。
  /// [read] は最大で指定した長さを返し、終端でのみそれより短くなる（Dart 版の ChunkedReader.read と同じ）。
  func encrypt(read: (Int) throws -> Data, write: (Data) throws -> Void, key: Data) throws {
    try encrypt(read: read, write: write, key: key, salt: randomBytes(32))
  }

  /// [salt] を指定して暗号化する（テストで既知の値と比べるため）。
  func encrypt(read: (Int) throws -> Data, write: (Data) throws -> Void, key: Data, salt: Data) throws {
    var header = Data(count: Self.headerLength)
    header.replaceSubrange(0..<6, with: Self.magic)
    header[6] = Self.version
    header.replaceSubrange(8..<16, with: Self.keyId(key))
    header.replaceSubrange(16..<20, with: withUnsafeBytes(of: UInt32(chunkSize).bigEndian) { Data($0) })
    header.replaceSubrange(20..<52, with: salt)
    try write(header)

    let fileKey = Self.fileKey(key, salt)
    var current = try read(chunkSize)
    var index = 0
    while true {
      let next = current.count == chunkSize ? try read(chunkSize) : Data()
      let isFinal = next.isEmpty
      try write(aead.seal(fileKey, Self.nonce(index, isFinal), current, header))
      if isFinal {
        break
      }
      current = next
      index += 1
    }
  }

  /// [read] から読んだ暗号化ファイルを復号して [write] に渡す。[read] は [encrypt] と同じ。
  func decrypt(read: (Int) throws -> Data, write: (Data) throws -> Void, key: Data) throws {
    let header = try read(Self.headerLength)
    if !Self.hasMagic(header) {
      throw NotEncryptedException()
    }
    if header.count < Self.headerLength {
      throw CorruptedFileException("ヘッダーが途中で切れています。")
    }
    let bytes = [UInt8](header)
    if bytes[6] != Self.version {
      throw CorruptedFileException("未対応の形式の版です（\(bytes[6])）。")
    }
    if !bytes[8..<16].elementsEqual(Self.keyId(key)) {
      throw WrongKeyException()
    }
    let fileChunkSize = bytes[16..<20].reduce(0) { $0 << 8 | Int($1) }
    if fileChunkSize == 0 || fileChunkSize > Self.maxChunkSize {
      throw CorruptedFileException("チャンク長が不正です（\(fileChunkSize)）。")
    }
    let fileKey = Self.fileKey(key, Data(bytes[20..<52]))
    let blockSize = fileChunkSize + Self.tagLength

    var current = try read(blockSize)
    var index = 0
    while true {
      if current.count < Self.tagLength {
        throw CorruptedFileException("データが途中で切れています。")
      }
      let next = current.count == blockSize ? try read(blockSize) : Data()
      let isFinal = next.isEmpty
      let plain: Data
      do {
        plain = try aead.open(fileKey, Self.nonce(index, isFinal), current, header)
      } catch is AuthenticationException {
        throw CorruptedFileException("改ざん、破損、または途中で切れたデータです。")
      }
      try write(plain)
      if isFinal {
        break
      }
      current = next
      index += 1
    }
  }

  /// ローカルの [from] を暗号化して [to] に書く（[to] は作り直す）。チャンクごとに読み書きし、別のスレッドで動かす。
  func encrypt(from: String, to: String, key: Data) async throws {
    try await Task.detached { [self] in
      try Self.pipe(from: from, to: to) { read, write in
        try encrypt(read: read, write: write, key: key)
      }
    }.value
  }

  /// [from] を復号して [to] に書く（[to] は作り直す）。チャンクごとに読み書きし、別のスレッドで動かす。
  func decrypt(from: String, to: String, key: Data) async throws {
    try await Task.detached { [self] in
      try decrypt(from: from, to: to, key: key, onRead: { _ in })
    }.value
  }

  /// [decrypt] の同期版。[onRead] には [from] から読んだ暗号化されたバイト列をそのまま渡す（ハッシュを取るためなど）。
  /// 時間がかかるので、呼ぶ側で Task.detached などの中から呼ぶ。
  func decrypt(from: String, to: String, key: Data, onRead: (Data) -> Void) throws {
    try Self.pipe(from: from, to: to) { read, write in
      try decrypt(
        read: { length in
          let bytes = try read(length)
          onRead(bytes)
          return bytes
        },
        write: write,
        key: key
      )
    }
  }

  /// [from] を読み、[to] を作り直して書く。途中で失敗したときの [to] はそのまま残す（Dart 版と同じ）。
  private static func pipe(
    from: String,
    to: String,
    _ body: (_ read: (Int) throws -> Data, _ write: (Data) throws -> Void) throws -> Void
  ) throws {
    let input = try FileHandle(fileDescriptor: openFile(from, O_RDONLY), closeOnDealloc: true)
    let output = try FileHandle(fileDescriptor: openFile(to, O_WRONLY | O_CREAT | O_TRUNC), closeOnDealloc: true)
    try body(
      { length in
        var bytes = Data()
        while bytes.count < length {
          guard let more = try input.read(upToCount: length - bytes.count), !more.isEmpty else {
            break
          }
          bytes.append(more)
        }
        return bytes
      },
      { try output.write(contentsOf: $0) }
    )
    try output.close()
  }

  private static func openFile(_ path: String, _ flags: Int32) throws -> Int32 {
    let fd = Darwin.open(path, flags | O_CLOEXEC, 0o666)
    if fd < 0 {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
    }
    return fd
  }

  private static func fileKey(_ key: Data, _ salt: Data) -> Data {
    let derived = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: key),
      salt: salt,
      info: fileKeyInfo,
      outputByteCount: 32
    )
    return derived.withUnsafeBytes { Data($0) }
  }

  private static func nonce(_ index: Int, _ isFinal: Bool) -> Data {
    var nonce = Data(count: 12)
    nonce.replaceSubrange(3..<11, with: withUnsafeBytes(of: UInt64(index).bigEndian) { Data($0) })
    nonce[11] = isFinal ? 1 : 0
    return nonce
  }
}

nonisolated struct NotEncryptedException: Error, CustomStringConvertible {
  init() {}

  var description: String { "このアプリで暗号化されたファイルではありません。" }
}

nonisolated struct WrongKeyException: Error, CustomStringConvertible {
  init() {}

  var description: String { "鍵が一致しません。別の鍵で暗号化されたファイルです。" }
}

nonisolated struct CorruptedFileException: Error, CustomStringConvertible {
  init(_ message: String) {
    self.message = message
  }

  let message: String

  var description: String { message }
}
