import Darwin
import Foundation

/// ファイル操作の失敗（Dart の FileSystemException の代わり）。
nonisolated struct FileSystemException: Error, CustomStringConvertible {
  init(_ message: String = "", _ path: String? = nil) {
    self.message = message
    self.path = path
  }

  let message: String
  let path: String?

  var description: String {
    var s = "FileSystemException: \(message)"
    if let path {
      s += ", path = '\(path)'"
    }
    return s
  }
}

/// ファイルシステムの項目の種類（Dart の FileSystemEntityType の代わり）。
nonisolated enum FileSystemEntityType: Sendable {
  case file
  case directory
  case link
  case notFound
  case other
}

/// stat の結果（Dart の FileStat の代わり）。
nonisolated struct FileStat: Sendable {
  let type: FileSystemEntityType
  let size: Int
  let modified: Date

  /// st_mode（種類のビットを含む。パーミッションは下位12ビット）。
  let mode: Int

  /// 存在しないときの値（Dart と同じく、サイズは -1）。
  static let notFound = FileStat(type: .notFound, size: -1, modified: Date(timeIntervalSince1970: 0), mode: 0)
}

private nonisolated func fileStat(_ path: String, follow: Bool) -> FileStat {
  var st = Darwin.stat()
  let rc = path.withCString { follow ? stat($0, &st) : lstat($0, &st) }
  if rc != 0 {
    return .notFound
  }
  let type: FileSystemEntityType =
    switch st.st_mode & S_IFMT {
    case S_IFREG: .file
    case S_IFDIR: .directory
    case S_IFLNK: .link
    default: .other
    }
  let modified = Date(
    timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000
  )
  return FileStat(type: type, size: Int(st.st_size), modified: modified, mode: Int(st.st_mode))
}

/// [path] の stat（シンボリックリンクは先をたどる。Dart の FileStat.stat と同じ）。なければ [FileSystemEntityType.notFound]。
nonisolated func statPath(_ path: String) -> FileStat { fileStat(path, follow: true) }

/// [path] の lstat（シンボリックリンクはたどらない）。
nonisolated func lstatPath(_ path: String) -> FileStat { fileStat(path, follow: false) }

/// [dir] の中の項目のパス（Dart の Directory.list(followLinks: false) と同じ）。開けなければ [FileSystemException]。
nonisolated func listDirectory(_ dir: String) throws -> [String] {
  do {
    return try FileManager.default.contentsOfDirectory(atPath: dir).map { p.join(dir, $0) }
  } catch {
    throw FileSystemException("Directory listing failed: \((error as NSError).localizedDescription)", dir)
  }
}

/// 一覧に出すファイル・フォルダー。
class LocalSource {
  var name: String { fatalError("LocalSource は LocalFile か LocalDir で使う") }
}

final class LocalFile: LocalSource {
  init(_ file: String, _ size: Int) {
    self.file = file
    self.size = size
  }

  let file: String
  let size: Int

  override var name: String { p.basename(file) }
}

final class LocalDir: LocalSource {
  init(_ directory: String) {
    self.directory = directory
  }

  let directory: String

  override var name: String { p.basename(directory) }
}

/// [path] の項目。シンボリックリンクなど通常のファイル・フォルダー以外は nil。
func localSourceOf(_ path: String, _ stat: FileStat) -> LocalSource? {
  switch stat.type {
  case .file: LocalFile(path, stat.size)
  case .directory: LocalDir(path)
  default: nil
  }
}

/// [dir] の中の名前（隠しファイルを含む）。
func dirNames(_ dir: String) async throws -> Set<String> {
  Set(try listDirectory(dir).map { p.basename($0) })
}

/// 同じ名前があれば「名前 (1).拡張子」の形で空いている名前を返す。
nonisolated func uniqueName(_ name: String, _ existing: Set<String>) -> String {
  if !existing.contains(name) {
    return name
  }
  let ext = p.extension(name)
  let base = ext.isEmpty ? name : String(name.unicodeScalars.dropLast(ext.unicodeScalars.count))
  var i = 1
  while true {
    let candidate = "\(base) (\(i))\(ext)"
    if !existing.contains(candidate) {
      return candidate
    }
    i += 1
  }
}

private var openTemps: [String] = []

/// 復号したファイルを開くための一時フォルダー。終了時に [deleteOpenTemps] で消す。
func createOpenTemp() async throws -> String {
  var template = Array(p.join(NSTemporaryDirectory(), "fm-ee2e-open-XXXXXX").utf8CString)
  guard mkdtemp(&template) != nil else {
    throw FileSystemException("Creation of temporary directory failed: \(String(cString: strerror(errno)))", NSTemporaryDirectory())
  }
  let dir = String(cString: template)
  openTemps.append(dir)
  return dir
}

/// [createOpenTemp] で作った一時フォルダーを消す。
func deleteOpenTemps() async {
  for dir in openTemps {
    // すでに消えている場合など。
    try? FileManager.default.removeItem(atPath: dir)
  }
  openTemps.removeAll()
}

/// [from] を [to] に複製する（フォルダーは中身ごと）。[to] はまだないパス。
func copyPath(_ from: String, _ to: String) async throws { try await runFileCommand("/bin/cp", ["-Rp", "--", from, to]) }

/// [from] を [to] に移す（別のボリュームへも）。[to] はまだないパス。
func movePath(_ from: String, _ to: String) async throws { try await runFileCommand("/bin/mv", ["--", from, to]) }

private func runFileCommand(_ command: String, _ args: [String]) async throws {
  let result = try await runProcess(command, args)
  if result.exitCode != 0 {
    throw FileSystemException(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), args.last)
  }
}

/// [path] を open に任せず端末のエディタで開くか。テキスト（または種類不明）のファイルで、
/// ユーザーが Finder の「すべてを変更」などで開くアプリを割り当てていないもの。
/// .md を MacVim が名乗るような、アプリ側が登録しているだけの既定は割り当てとみなさない。
func shouldEditInTerminal(_ path: String) async -> Bool {
  // 問い合わせに失敗したら、これまでどおり open に任せる。
  guard
    let result = try? await runProcess(
      "/usr/bin/osascript",
      ["-l", "JavaScript", "-e", editCheckScript, p.absolute(path)]
    )
  else {
    return false
  }
  return result.exitCode == 0 && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
}

private let editCheckScript = #"""
  ObjC.import("AppKit");
  function run(argv) {
    const ws = $.NSWorkspace.sharedWorkspace;
    const path = argv[0];
    const type = ObjC.unwrap(ws.typeOfFileError(path, null)) || "public.data";
    const unknown = type === "public.data" || type.startsWith("dyn.");
    if (!unknown && !ws.typeConformsToType(type, "public.text")) return false;
    const ext = ObjC.unwrap($(path).pathExtension).toLowerCase();
    const plist = ObjC.deepUnwrap($.NSDictionary.dictionaryWithContentsOfFile(
      $("~/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist").stringByExpandingTildeInPath));
    const handlers = (plist && plist.LSHandlers) || [];
    const assigned = handlers.some(h => {
      const role = h.LSHandlerRoleAll || h.LSHandlerRoleViewer || h.LSHandlerRoleEditor;
      if (!role || role === "-") return false;
      if (h.LSHandlerContentType === type) return true;
      return ext !== "" && h.LSHandlerContentTagClass === "public.filename-extension"
        && String(h.LSHandlerContentTag).toLowerCase() === ext;
    });
    return !assigned;
  }

  """#

/// 既定のアプリで開く。
func openFile(_ path: String) async throws {
  let result = try await runProcess("/usr/bin/open", [p.absolute(path)])
  if result.exitCode != 0 {
    throw FileSystemException(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), path)
  }
}

/// ゴミ箱へ移す（macOSの /usr/bin/trash）。[path] は絶対パスで渡す（「-」で始まる名前をオプションと誤認させない）。
func moveToTrash(_ path: String) async throws {
  let result = try await runProcess("/usr/bin/trash", [p.absolute(path)])
  if result.exitCode != 0 {
    throw FileSystemException(tr("local_files.trash_failed"), path)
  }
}
