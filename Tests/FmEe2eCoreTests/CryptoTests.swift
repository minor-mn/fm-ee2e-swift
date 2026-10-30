import Foundation
import Testing

@testable import FmEe2eCore

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

private func unhex(_ text: String) -> Data {
  var data = Data()
  var index = text.startIndex
  while index < text.endIndex {
    let next = text.index(index, offsetBy: 2)
    data.append(UInt8(text[index..<next], radix: 16)!)
    index = next
  }
  return data
}

/// 鍵 0x00..0x1f。以下の既知の値は Dart 版（fm-ee2e-tui の DartAead・NameCipher・KeyFile）で作ったもの。
private let testKey = Data((0..<32).map { UInt8($0) })

private func plainBytes(_ length: Int) -> Data { Data((0..<length).map { UInt8(($0 * 7 + 3) & 0xff) }) }

/// Dart 版で chunkSize 16 で暗号化したもの（平文の長さ → 暗号化ファイル）。
private let dartFiles: [(Int, String)] = [
  (0, "464d45453245010051d7097479f797ba0000001076595a8c612781deb46480d0e8b4ae3ebe4da0589262489df15330eee498ab4fa6d49c1ab481c882079a4a28e3259121"),
  (16, "464d45453245010051d7097479f797ba0000001012be085aa3490e76bb6eb7a0cff38ca84eef1fef5546bcc8ffec849d341673ba884e771405c53300ecd9dee7084711b03c42661d03fc52fc8f03f7b478ed23ec"),
  (32, "464d45453245010051d7097479f797ba00000010cb5f292aa7976dbfc25885e9b44ce3bebd667e4d97fc93a0838c2e7a9a18343a3441afa4efd11b10575184c4243dea461fcda9fb92d48fff535f90590ec05435b464cd4797dd7e6e91c21613fac10e65d1d8340e7f55cf19815b8d2060e1c7a9"),
  (40, "464d45453245010051d7097479f797ba000000109208c6e00b513952a0a927078d19d4def811dae5c112a270b1f6c0e4c0c2d8a04bf8a51770ce5d7bedcf740527dce3d3390d166a5264a5d2e70b05f47f7dfc92e5db498a751ad03ace234bffc2ba657b308fa960db0593e8749e348b890c50490d2c3c3d860feb068f8d63e2bbe59a37ea13adceec5b6ad7"),
]

/// Dart 版で暗号化した名前（平文、フォルダーか、暗号化した名前）。
private let dartNames: [(String, Bool, String)] = [
  ("レポート.pdf", false, "Aa56Gz2liBrx-VPAFxVsoqgNHU8ZEIqwER_0NUSKjbx8b1gml7oa7bo.pdf"),
  (".bashrc", false, "AcSbFC9UHOgrt-b5sfUS9WzmsZv250lutIaBDm7JLMnF-pS_"),
  ("archive.tar.gz", false, "Aekm97uhUVlkL4zUnAtY1BEWDYPzwvVDEZ4occGnr2PZRJCHZ7mpXg.gz"),
  ("フォルダ.d", true, "Ab9zqQyAphXh4_tr0SvMMnclIs-bhtHbttkogP5T1VV0D-Gqu2jBV5ykIA"),
  ("noext", false, "AeWDfxQluebUTebw-L43lpZYmrM_8d2osA0XW_8Jkt0jHA"),
  ("", false, "AexdbWm59BPb0xQ2rGIVq0LFJOma3c6SMSOrO88"),
  ("\u{304C}.txt", false, "ATybYGP4mosgtnj4bYJJ1JZbMR-fJwaiLedzYysSLLo.txt"),
]

/// メモリー上のバイト列を、指定した長さずつ返す。
private func reader(_ data: Data) -> (Int) throws -> Data {
  var offset = 0
  return { length in
    let end = min(offset + length, data.count)
    defer { offset = end }
    return data.subdata(in: offset..<end)
  }
}

private func encrypt(_ format: EncryptedFormat, _ plain: Data, key: Data = testKey, salt: Data? = nil) throws -> Data {
  var out = Data()
  if let salt {
    try format.encrypt(read: reader(plain), write: { out.append($0) }, key: key, salt: salt)
  } else {
    try format.encrypt(read: reader(plain), write: { out.append($0) }, key: key)
  }
  return out
}

private func decrypt(_ format: EncryptedFormat, _ encrypted: Data, key: Data = testKey) throws -> Data {
  var out = Data()
  try format.decrypt(read: reader(encrypted), write: { out.append($0) }, key: key)
  return out
}

private func withTempDir<T>(_ body: (String) async throws -> T) async throws -> T {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fm-ee2e-test-\(UUID().uuidString)").path
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: dir) }
  return try await body(dir)
}

@Suite struct EncryptedFormatTests {
  let format = EncryptedFormat(CryptoKitAead.load(), chunkSize: 16)

  @Test func keyIdMatchesDart() {
    #expect(hex(EncryptedFormat.keyId(testKey)) == "51d7097479f797ba")
  }

  @Test func decryptsDartFiles() throws {
    for (length, encrypted) in dartFiles {
      // 読み出す側のチャンク長はヘッダーから取るので、既定のチャンク長の形式でも読める。
      #expect(try decrypt(EncryptedFormat(CryptoKitAead.load()), unhex(encrypted)) == plainBytes(length))
    }
  }

  @Test func encryptsSameBytesAsDartForSameSalt() throws {
    for (length, encrypted) in dartFiles {
      let expected = unhex(encrypted)
      let salt = expected.subdata(in: 20..<52)
      #expect(try hex(encrypt(format, plainBytes(length), salt: salt)) == encrypted)
      #expect(format.encryptedLength(length) == expected.count)
    }
  }

  @Test func roundTripsAndUsesFreshSalt() throws {
    for length in [0, 1, 15, 16, 17, 48, 100] {
      let plain = randomBytes(length)
      let a = try encrypt(format, plain)
      let b = try encrypt(format, plain)
      #expect(a.count == format.encryptedLength(length))
      #expect(a != b)
      #expect(try decrypt(format, a) == plain)
    }
  }

  @Test func rejectsWrongKeyAndForeignFiles() throws {
    let encrypted = try encrypt(format, plainBytes(40))
    #expect(throws: WrongKeyException.self) { try decrypt(format, encrypted, key: Data(repeating: 1, count: 32)) }
    #expect(throws: NotEncryptedException.self) { try decrypt(format, Data("hello".utf8)) }
    #expect(throws: CorruptedFileException.self) { try decrypt(format, encrypted.prefix(30)) }
    #expect(EncryptedFormat.hasMagic(encrypted))
    #expect(!EncryptedFormat.hasMagic(Data("FMEE2".utf8)))
  }

  @Test func detectsTamperingAndTruncation() throws {
    let encrypted = try encrypt(format, plainBytes(40))
    // 本体の1バイトを書き換える。
    var tampered = encrypted
    tampered[60] ^= 1
    #expect(throws: CorruptedFileException.self) { try decrypt(format, tampered) }
    // ヘッダー（AAD）のソルトを書き換える。
    var header = encrypted
    header[30] ^= 1
    #expect(throws: CorruptedFileException.self) { try decrypt(format, header) }
    // チャンクの境目で切る（終端の印がないので検出される）。
    #expect(throws: CorruptedFileException.self) { try decrypt(format, encrypted.prefix(52 + 32)) }
    // 途中で切る。
    #expect(throws: CorruptedFileException.self) { try decrypt(format, encrypted.prefix(encrypted.count - 1)) }
    // 後ろに余分なデータ。
    #expect(throws: CorruptedFileException.self) { try decrypt(format, encrypted + Data([0])) }
  }

  @Test func encryptsAndDecryptsFiles() async throws {
    try await withTempDir { dir in
      let format = EncryptedFormat(CryptoKitAead.load(), chunkSize: 1000)
      let plain = randomBytes(12345)
      let source = "\(dir)/plain"
      let encrypted = "\(dir)/encrypted"
      let decrypted = "\(dir)/decrypted"
      try plain.write(to: URL(fileURLWithPath: source))
      try await format.encrypt(from: source, to: encrypted, key: testKey)
      let encryptedBytes = try Data(contentsOf: URL(fileURLWithPath: encrypted))
      #expect(encryptedBytes.count == format.encryptedLength(plain.count))
      // 既にあるファイルは作り直す。
      try Data(repeating: 9, count: 50000).write(to: URL(fileURLWithPath: decrypted))
      try await format.decrypt(from: encrypted, to: decrypted, key: testKey)
      #expect(try Data(contentsOf: URL(fileURLWithPath: decrypted)) == plain)

      var seen = Data()
      try format.decrypt(from: encrypted, to: decrypted, key: testKey, onRead: { seen.append($0) })
      #expect(seen == encryptedBytes)

      await #expect(throws: WrongKeyException.self) {
        try await format.decrypt(from: encrypted, to: decrypted, key: Data(repeating: 0, count: 32))
      }
      await #expect(throws: (any Error).self) {
        try await format.encrypt(from: "\(dir)/missing", to: encrypted, key: testKey)
      }
    }
  }
}

@Suite struct NameCipherTests {
  let names = NameCipher(testKey)

  @Test func decryptsDartNames() {
    for (plain, isFolder, encrypted) in dartNames {
      #expect(names.decrypt(encrypted, isFolder: isFolder) == plain)
    }
  }

  @Test func roundTripsAndKeepsExtension() {
    let nfd = "\u{304B}\u{3099}\u{30A4}\u{30C8}\u{3099}.txt"
    for (plain, isFolder) in [("レポート.pdf", false), (".bashrc", false), ("a.b.c", false), ("フォルダ.d", true), ("", false), (nfd, false)] {
      let encrypted = names.encrypt(plain, isFolder: isFolder)
      let decrypted = names.decrypt(encrypted, isFolder: isFolder)
      #expect(decrypted == plain)
      // NFD のままバイト列も同じ。
      #expect(decrypted.map { Array($0.utf8) } == Array(plain.utf8))
      #expect(!encrypted.contains("="))
    }
    #expect(names.encrypt("a.b.c", isFolder: false).hasSuffix(".c"))
    #expect(names.encrypt("x.tar", isFolder: false) != names.encrypt("x.tar", isFolder: false))
  }

  @Test func rejectsOtherNames() {
    let encrypted = names.encrypt("report.pdf", isFolder: false)
    #expect(names.decrypt(String(encrypted.dropLast(4)) + ".txt", isFolder: false) == nil)
    #expect(names.decrypt(encrypted, isFolder: true) == nil)
    #expect(NameCipher(Data(repeating: 7, count: 32)).decrypt(encrypted, isFolder: false) == nil)
    #expect(names.decrypt("report.pdf", isFolder: false) == nil)
    #expect(names.decrypt("日本語", isFolder: true) == nil)
    #expect(names.decrypt("", isFolder: true) == nil)
  }

  /// Dart の base64Url.normalize + decode / base64.decode と同じ結果になること（Dart で確かめた値）。
  @Test func decodesBase64LikeDart() {
    let cases: [(String, [UInt8]?, [UInt8]?)] = [
      // (入力, パディングなしも許す, パディング必須)
      ("AQID", [1, 2, 3], [1, 2, 3]),
      ("AQI", [1, 2], nil),
      ("AQI=", [1, 2], [1, 2]),
      ("AQ", [1], nil),
      ("AQ==", [1], [1]),
      ("AQ=", nil, nil),
      ("A", nil, nil),
      ("AR", nil, nil),
      ("AQ-_", [1, 15, 191], [1, 15, 191]),
      ("AQ+/", [1, 15, 191], [1, 15, 191]),
      ("A Q", nil, nil),
      ("AQ==AQ==", nil, nil),
      ("", [], []),
      ("-_8", [251, 255], nil),
    ]
    for (text, loose, strict) in cases {
      #expect(decodeBase64(text, requirePadding: false).map { [UInt8]($0) } == loose, "\(text)")
      #expect(decodeBase64(text, requirePadding: true).map { [UInt8]($0) } == strict, "\(text)")
    }
  }
}

@Suite struct KeyFileTests {
  @Test func encodesLikeDart() throws {
    let text = KeyFile.encode(testKey)
    #expect(text == "fm-ee2e-key-v1\nAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=\n")
    #expect(try KeyFile.decode(text) == testKey)
    #expect(try KeyFile.decode("\u{FEFF}  \r\n fm-ee2e-key-v1 \r\n\r\nAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=  \n\n") == testKey)
    #expect(KeyFile.generate().count == 32)
    #expect(KeyFile.generate() != KeyFile.generate())
  }

  @Test func rejectsBadText() {
    #expect(throws: AppError.self) { try KeyFile.decode("") }
    #expect(throws: AppError.self) { try KeyFile.decode("fm-ee2e-key-v2\nAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=") }
    #expect(throws: AppError.self) { try KeyFile.decode("fm-ee2e-key-v1\nAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8") }
    #expect(throws: AppError.self) { try KeyFile.decode("fm-ee2e-key-v1\nAAEC") }
    #expect(throws: AppError.self) { try KeyFile.decode("fm-ee2e-key-v1\nAAEC\nAAEC") }
  }

  @Test func savesAndLoads() async throws {
    try await withTempDir { dir in
      let path = "\(dir)/key"
      #expect(try await KeyFile.load(path) == nil)
      #expect(try await KeyFile.load(dir) == nil)
      try await KeyFile.save(path, testKey)
      #expect(try await KeyFile.load(path) == testKey)
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      #expect((attributes[.posixPermissions] as? Int) == 0o600)
      // 既にあれば上書きしない。
      await #expect(throws: (any Error).self) { try await KeyFile.save(path, Data(repeating: 1, count: 32)) }
      #expect(try await KeyFile.load(path) == testKey)
    }
  }

  @Test func saveCreatesFolder() async throws {
    try await withTempDir { dir in
      let path = "\(dir)/.config/fm-ee2e/.fm-ee2e.key"
      try await KeyFile.save(path, testKey)
      #expect(try await KeyFile.load(path) == testKey)
    }
  }
}
