import Darwin
import Foundation

/// 鍵ファイルのテキスト形式。
///
/// ```
/// fm-ee2e-key-v1
/// <鍵32バイトのBase64>
/// ```
enum KeyFile {
  static let header = "fm-ee2e-key-v1"
  static let keyLength = 32

  static func generate() -> Data { randomBytes(keyLength) }

  static func encode(_ key: Data) -> String {
    precondition(key.count == keyLength, "鍵は\(keyLength)バイトである必要があります。")
    return "\(header)\n\(key.base64EncodedString())\n"
  }

  /// 鍵テキストを解析する。ペーストされたテキストの前後の空白や改行は許容する。
  /// 形式が違えば [AppError]（Dart 版の FormatException）。
  static func decode(_ text: String) throws -> Data {
    // Dart の String.trim と同じく BOM も空白として扱う。
    let blank = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
    let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: blank) }.filter { !$0.isEmpty }
    if lines.count != 2 || lines[0] != header {
      throw AppError(tr("key_file.bad_format", ["header": header]))
    }
    guard let key = decodeBase64(lines[1], requirePadding: true) else {
      throw AppError(tr("key_file.bad_base64"))
    }
    if key.count != keyLength {
      throw AppError(tr("key_file.bad_length", ["expected": keyLength, "actual": key.count]))
    }
    return key
  }

  /// 鍵ファイルを読み込む。ファイルがなければ nil。
  static func load(_ file: String) async throws -> Data? {
    var isDir: ObjCBool = false
    if !FileManager.default.fileExists(atPath: file, isDirectory: &isDir) || isDir.boolValue {
      return nil
    }
    return try decode(String(contentsOfFile: file, encoding: .utf8))
  }

  /// 鍵ファイルを新規作成する。既にファイルがある場合は上書きせずに失敗する。置くフォルダーがなければ作る。
  static func save(_ file: String, _ key: Data) async throws {
    let text = encode(key)
    try FileManager.default.createDirectory(atPath: p.dirname(file), withIntermediateDirectories: true)
    // 中身を書く前にパーミッションを絞る。
    let fd = Darwin.open(file, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    if fd < 0 {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: file])
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
      if fchmod(fd, 0o600) != 0 {
        throw AppError(tr("key_file.cannot_set_permission", ["reason": String(cString: strerror(errno))]))
      }
      try handle.write(contentsOf: Data(text.utf8))
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      unlink(file)
      throw error
    }
  }
}
