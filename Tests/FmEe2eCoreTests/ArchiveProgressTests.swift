import Foundation
import Testing

@testable import FmEe2eCore

@MainActor
struct ArchiveProgressTests {
  @Test(arguments: [ArchiveFormat.zip, .tarGz])
  func reportsEachEntryWhenCompressingAndExtracting(_ format: ArchiveFormat) async throws {
    let dir = try makeTempDir("fm-ee2e-archive-test-")
    defer {
      try? FileManager.default.removeItem(atPath: dir)
    }
    // src/、src/d/、ファイル5つ（src/a・src/d/f0〜f3）の7項目。
    let src = p.join(dir, "src")
    try FileManager.default.createDirectory(atPath: p.join(src, "d"), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: p.join(src, "a"), contents: Data("a".utf8))
    for i in 0..<4 {
      FileManager.default.createFile(atPath: p.join(src, "d", "f\(i)"), contents: Data("\(i)".utf8))
    }
    let output = p.join(dir, "out\(format.extension)")
    var compressed: [(Int, Int, String)] = []
    try await compressPaths([src], output, format) { compressed.append(($0, $1, $2)) }
    #expect(compressed.count == 7)
    #expect(compressed.allSatisfy { $0.1 == 7 })
    #expect(compressed.last?.0 == 7)
    #expect(compressed.contains { $0.2 == "src/d/f3" })

    let dest = p.join(dir, "dest")
    try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
    let items = try await listArchive(output)
    var extracted: [(Int, Int, String)] = []
    try await extractArchive(output, items, dest, keepExisting: false) { extracted.append(($0, $1, $2)) }
    #expect(extracted.count == items.count)
    #expect(extracted.last?.0 == items.count)
    #expect(FileManager.default.fileExists(atPath: p.join(dest, "src", "d", "f3")))
  }

  @Test func failureMessageLeavesOutProgressLines() async {
    await #expect(throws: FileSystemException.self) {
      try await compressPaths(["/no/such/path"], "/no/such/out.zip", .zip)
    }
  }
}
