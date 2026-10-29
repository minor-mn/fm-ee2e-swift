import CryptoKit
import Foundation

/// Google Drive のファイルをエディタで編集する（E・F8）。
///
/// 1. Drive の暗号化ファイルを、このアプリの編集用のフォルダー（[editRoot]、本人だけが読める）に元の名前で復号する。
///    そのとき、暗号化ファイルと平文のハッシュを取っておく。
/// 2. 枠の中のエディタで開き、閉じるまで待つ。
/// 3. 平文が変わっていれば、Drive の暗号化ファイルが開いたときのままかをハッシュで確かめてから、暗号化し直して置く。
///    変わっていれば、上書き・別の名前で保存・保存しないを選ばせる。
/// 4. 平文を消す。
///
/// アプリが途中で落ちると平文が [editRoot] に残るので、次に Google Drive のタブを使えるようになったときに
/// Drive に保存するか捨てるかを聞く（[recoverEdits]）。
final class DriveEditSession {
  private init(_ dir: String, _ source: String, _ name: String, _ cipherHash: String, _ plainHash: String) {
    self.dir = dir
    self.source = source
    self.name = name
    self.cipherHash = cipherHash
    self.plainHash = plainHash
  }

  /// 編集用のフォルダー。平文（[name]）と、編集の情報（[metaName]）を置く。
  let dir: String

  /// Drive の暗号化ファイル。
  let source: String

  /// 一覧での名前（復号したもの）。
  let name: String

  /// 開いたときの、Drive の暗号化ファイルと平文のハッシュ。
  let cipherHash: String
  let plainHash: String

  var plainPath: String { p.join(dir, name) }

  private static let metaName = ".fm-ee2e-edit.json"

  /// 編集中の平文を置く場所。
  static var editRoot: String { p.join(homeDir, "Library", "Caches", "fm-ee2e", "edit") }

  /// [source] を編集用のフォルダーに復号する。
  static func start(_ drive: DrivePane, _ source: String, _ name: String) async throws -> DriveEditSession {
    let root = editRoot
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    _ = try? await runProcess("chmod", ["700", root])
    let dir = try makeTempDir("edit-", in: root)
    do {
      let cipherHash = try hashOf(source)
      try await drive.format!.decrypt(from: source, to: p.join(dir, name), key: drive.key!)
      let session = DriveEditSession(dir, source, name, cipherHash, try hashOf(p.join(dir, name)))
      let meta: [String: String] = [
        "source": source, "name": name, "cipherHash": session.cipherHash, "plainHash": session.plainHash,
      ]
      try JSONSerialization.data(withJSONObject: meta).write(to: URL(fileURLWithPath: p.join(dir, metaName)))
      return session
    } catch {
      try? FileManager.default.removeItem(atPath: dir)
      throw error
    }
  }

  /// [editRoot] に残っている編集。読めないものは飛ばす。
  static func leftovers() async -> [DriveEditSession] {
    guard let children = try? listDirectory(editRoot) else {
      return []
    }
    var sessions: [DriveEditSession] = []
    for path in children where statPath(path).type == .directory {
      // 情報を書く前に落ちたものなどは飛ばす。
      guard let data = FileManager.default.contents(atPath: p.join(path, metaName)),
        let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let source = meta["source"] as? String,
        let name = meta["name"] as? String,
        let cipherHash = meta["cipherHash"] as? String,
        let plainHash = meta["plainHash"] as? String
      else {
        continue
      }
      let session = DriveEditSession(path, source, name, cipherHash, plainHash)
      if statPath(session.plainPath).type == .file {
        sessions.append(session)
      }
    }
    return sessions
  }

  /// 平文が変わっていれば Drive に保存し、平文を消す。保存した Drive での名前（一覧での名前）を返す。
  /// 確認の小窓を閉じた（キャンセルした）ときは、平文を残して nil を返す（あとで [recoverEdits] で聞く）。
  @discardableResult
  func save(_ drive: DrivePane) async throws -> String? {
    let app = drive.app
    if try Self.hashOf(plainPath) == plainHash {
      try discard()
      return name
    }
    let parent = p.dirname(source)
    var target = name
    let current = FileManager.default.fileExists(atPath: source) ? try Self.hashOf(source) : nil
    var replaced: String? = current == nil ? nil : source
    if current != cipherHash {
      let choice = await app.askChoice(
        "Google Drive のファイルが変わっています",
        ["上書きする", "別の名前で保存する", "保存しない"],
        note: current == nil ? "「\(name)」は開いたあとに Google Drive から消えています。" : "「\(name)」は開いたあとに Google Drive で変わっています。"
      )
      switch choice {
      case 0:
        break
      case 1:
        replaced = nil
        target = uniqueName(name, Set(try await drive.itemsIn(parent).keys))
      case 2:
        try discard()
        return nil
      default:
        return nil
      }
    }
    try await app.withProgress("「\(target)」を暗号化中…") {
      let to = try await drive.encryptedPath(parent, target, isFolder: false)
      try await drive.encryptFile(plainPath, to)
      // 新しいものを置き終えてから、上書きされる側をゴミ箱に移す。
      if let replaced {
        try await moveToTrash(replaced)
      }
      drive.evictLater([to])
    }
    try discard()
    return target
  }

  /// 平文と編集の情報を消す。
  func discard() throws {
    try FileManager.default.removeItem(atPath: dir)
  }

  private static func hashOf(_ path: String) throws -> String {
    guard let handle = FileHandle(forReadingAtPath: path) else {
      throw AppError("\(path) を開けません。")
    }
    defer {
      try? handle.close()
    }
    var hash = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      hash.update(data: chunk)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

/// [source] を復号してエディタで開き、閉じたら保存する。
func editOnDrive(_ drive: DrivePane, _ source: String, _ name: String) async throws {
  let app = drive.app
  let session = try await app.withProgress("「\(name)」を復号中…") { try await DriveEditSession.start(drive, source, name) }
  await editInTerminal(app, session.plainPath, workingDirectory: session.dir)
  var saved: String?
  do {
    saved = try await session.save(drive)
  } catch {
    // 平文は残す（次に起動したときに聞く）。
    await app.showError("保存できませんでした。編集した内容は次に起動したときに保存できます。\n\(errorMessage(error))")
  }
  await drive.load(focus: saved ?? name)
}

/// 前に落ちたときなどに残った編集を、Drive に保存するか捨てるか聞く。
func recoverEdits(_ drive: DrivePane) async {
  let app = drive.app
  for session in await DriveEditSession.leftovers() {
    let choice = await app.askChoice(
      "保存されていない編集があります",
      ["Google Drive に保存する", "捨てる"],
      note: "「\(session.name)」を編集したまま、Google Drive に保存されていません。"
    )
    do {
      switch choice {
      case 0:
        try await session.save(drive)
      case 1:
        try session.discard()
      default:
        break
      }
    } catch {
      await app.showError("保存できませんでした。\n\(errorMessage(error))")
    }
  }
  await drive.load()
}
