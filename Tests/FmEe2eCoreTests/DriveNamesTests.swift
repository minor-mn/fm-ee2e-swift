import Foundation
import Testing

@testable import FmEe2eCore

@MainActor
struct DriveNamesTests {
  private let names = DriveNames(NameCipher(Data((0..<32).map { UInt8($0) })))

  private func withTempDir(_ body: (String) async throws -> Void) async throws {
    let dir = try makeTempDir("fm-ee2e-names-test-")
    defer {
      try? FileManager.default.removeItem(atPath: dir)
    }
    try await body(dir)
  }

  private func children(_ dir: String) throws -> Set<String> { Set(try listDirectory(dir).map { p.basename($0) }) }

  /// 日本語で約53文字を超えると、拡張子4文字のファイルの暗号化した名前は 220 文字を超える。
  private let longName = String(repeating: "長い名前", count: 20) + ".pdf"

  @Test func shortNameIsEncryptedInPlace() async throws {
    try await withTempDir { dir in
      let path = try await names.place(dir, "レポート.pdf", isFolder: false) { FileManager.default.createFile(atPath: $0, contents: nil) }
      #expect(try children(dir) == [p.basename(path)])
      #expect(names.shown(dir, p.basename(path), isFolder: false) == "レポート.pdf")
      #expect(DriveNames.existingNameFile(of: path) == nil)
    }
  }

  @Test func longFileNameUsesNameFile() async throws {
    try await withTempDir { dir in
      let path = try await names.place(dir, longName, isFolder: false) { FileManager.default.createFile(atPath: $0, contents: nil) }
      let body = p.basename(path)
      #expect(body.count == DriveNames.hashLength + 4 && body.hasSuffix(".pdf"))
      let nameFile = try #require(DriveNames.existingNameFile(of: path))
      #expect(p.basename(nameFile) == ".\(body.dropLast(4))\(DriveNames.nameFileSuffix)")
      #expect(DriveNames.isNameFile(p.basename(nameFile)))
      let siblings = try children(dir)
      #expect(siblings == [body, p.basename(nameFile)])
      // 一覧を読んだときの名前で確かめても、ファイルの有無で確かめても、元の名前になる。
      #expect(names.shown(dir, body, isFolder: false, siblings: siblings) == longName)
      #expect(names.shown(dir, body, isFolder: false) == longName)
      // 一覧に名前ファイルがなければ、読みに行かない。
      #expect(names.shown(dir, body, isFolder: false, siblings: [body]) == body)
    }
  }

  @Test func longFolderNameUsesNameFile() async throws {
    try await withTempDir { dir in
      let name = String(repeating: "フォルダー", count: 20)
      let path = try await names.place(dir, name, isFolder: true) { try FileManager.default.createDirectory(atPath: $0, withIntermediateDirectories: false) }
      #expect(p.basename(path).count == DriveNames.hashLength)
      #expect(names.shown(dir, p.basename(path), isFolder: true) == name)
      // ファイルとしては読めない（フォルダーとファイルの取り違え）。
      #expect(names.shown(dir, p.basename(path), isFolder: false) == p.basename(path))
    }
  }

  @Test func tooLongExtensionIsDroppedFromBody() async throws {
    try await withTempDir { dir in
      let name = "a." + String(repeating: "x", count: 200)
      let path = try await names.place(dir, name, isFolder: false) { FileManager.default.createFile(atPath: $0, contents: nil) }
      #expect(p.basename(path).count == DriveNames.hashLength)
      #expect(names.shown(dir, p.basename(path), isFolder: false) == name)
    }
  }

  @Test func nameFileOfAnotherBodyIsNotUsed() async throws {
    try await withTempDir { dir in
      let first = try await names.place(dir, longName, isFolder: false) { FileManager.default.createFile(atPath: $0, contents: nil) }
      let second = try await names.place(dir, "別の" + longName, isFolder: false) { FileManager.default.createFile(atPath: $0, contents: nil) }
      // 2つ目の名前ファイルを、1つ目の名前ファイルの中身で書き換える。
      let firstNameFile = try #require(DriveNames.existingNameFile(of: first))
      let secondNameFile = try #require(DriveNames.existingNameFile(of: second))
      try FileManager.default.removeItem(atPath: secondNameFile)
      try FileManager.default.copyItem(atPath: firstNameFile, toPath: secondNameFile)
      #expect(names.shown(dir, p.basename(second), isFolder: false) == p.basename(second))
    }
  }

  @Test func failedPutRemovesNameFile() async throws {
    try await withTempDir { dir in
      await #expect(throws: AppError.self) {
        try await names.place(dir, longName, isFolder: false) { _ in throw AppError("失敗") }
      }
      let left = try children(dir)
      #expect(left.isEmpty)
    }
  }
}
