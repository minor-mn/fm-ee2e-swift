import Foundation
import Testing

@testable import FmEe2eCore

private func parse(_ text: String) throws -> AppConfig { try AppConfig.parse(Data(text.utf8)) }

@Test func exampleConfigIsAllOn() throws {
  let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../config.example.json5")
  #expect(try AppConfig.parse(Data(contentsOf: file)).rightTabs == RightMode.allCases)
}

@Test func falseTabsAreHidden() throws {
  let config = try parse(#"{ "right_tabs": { "git": false, "ssh": false, "local": true } }"#)
  #expect(config.rightTabs == RightMode.allCases.filter { $0 != .git && $0 != .ssh })
}

@Test func emptyConfigIsDefault() throws {
  #expect(try parse(" \n").rightTabs == RightMode.allCases)
  #expect(try parse("{}").rightTabs == RightMode.allCases)
}

@Test func badConfigIsRejected() {
  #expect(throws: ConfigFormatError.self) { try parse(#"{ "right_tabs": { "git": 0 } }"#) }
  #expect(throws: ConfigFormatError.self) { try parse(#"{ "right_tabs": { "gitt": true } }"#) }
  #expect(throws: ConfigFormatError.self) { try parse("right_tabs:\n  git: off\n") }
  #expect(throws: ConfigFormatError.self) { try parse("[]") }
}

@Test func tabsInheritDefaultThenWindow() throws {
  let config = try parse(
    ##"""
    { "appearance": {
      "window": { "font": { "size": 14 }, "text": { "color": "#111111" }, "subtext": { "color": "#222222" },
                  "background": { "color": "#000000" } },
      "default": { "text": { "color": "#333333" }, "background": { "image": { "path": "/tmp/a.png" } } },
      "git": { "accent": { "color": "#444444" }, "font": { "size": 18 }, "background": null }
    } }
    """##)
  let appearance = config.appearance
  let local = appearance.theme(.local)
  // 書いていないタブは default、default にない項目は window。
  #expect(local.colors.text == Rgb(0x333333))
  #expect(local.colors.muted == Rgb(0x222222))
  #expect(local.font.size == 14)
  #expect(local.background?.image?.path == "/tmp/a.png")
  // タブの項目は default を上書きし、null は引き継いだ値を消す。
  let git = appearance.theme(.git)
  #expect(git.colors.accent == Rgb(0x444444))
  #expect(git.colors.text == Rgb(0x333333))
  #expect(git.font.size == 18)
  #expect(git.background == nil)
  let image = try parse(
    ##"{ "appearance": { "git": { "background": { "image": { "path": "a.png", "align": "bottom_right", "max_width": 0.4, "max_height": 0.4 } } } } }"##
  ).appearance.theme(.git).background?.image
  let colors = try parse(
    ##"""
    { appearance: { git: {
      diff: { added: { color: "#00FF00", background: { color: "#12392D80" } } },
      files: { directory: { color: "#0000FF" } },
      cursor: { background: { color: "#333333" } },
    } } }
    """##
  ).appearance.theme(.git).colors
  #expect(colors.diffAdded == Rgb(0x00FF00))
  #expect(colors.addedLine == Rgb(0x12392D))
  #expect(colors.alphas[0x12392D] == Double(0x80) / 255)
  #expect(colors.directory == Rgb(0x0000FF))
  #expect(colors.selection == Rgb(0x333333))
  #expect(image?.align == .bottomRight)
  #expect(image?.maxWidth == 0.4)
  #expect(image?.maxHeight == 0.4)
  #expect(appearance.window.font.size == 14)
}

@Test func windowOnlyAppliesToWholeWindow() throws {
  let appearance = try parse(
    ##"{ "appearance": { "window": { "opacity": 0.8, "blur": true, "background": { "color": "#10203080" } } } }"##
  ).appearance
  #expect(appearance.opacity == 0.8)
  #expect(appearance.blur)
  // タブは背景を塗らずに、窓全体の背景を見せる。
  #expect(appearance.theme(.ssh).background == nil)
  #expect(appearance.theme(.ssh).colors.background == Rgb(0x102030))
  #expect(appearance.window.background?.color == Rgba(Rgb(0x102030), Double(0x80) / 255))
}

@Test func badAppearanceIsRejected() {
  #expect(throws: ConfigFormatError.self) { try parse(##"{ "appearance": { "tab": {} } }"##) }
  #expect(throws: ConfigFormatError.self) { try parse(##"{ "appearance": { "git": { "opacity": 0.5 } } }"##) }
  #expect(throws: ConfigFormatError.self) { try parse(##"{ "appearance": { "window": { "text": { "color": "#12" } } } }"##) }
  // もうない書き方・ない要素・文字の色の透明度はエラー。
  #expect(throws: ConfigFormatError.self) { try parse(##"{ appearance: { git: { colors: { text: "#111111" } } } }"##) }
  #expect(throws: ConfigFormatError.self) { try parse(##"{ appearance: { git: { diff: { changed: { color: "#111111" } } } } }"##) }
  #expect(throws: ConfigFormatError.self) { try parse(##"{ appearance: { git: { text: { color: "#11111180" } } } }"##) }
  #expect(throws: ConfigFormatError.self) { try parse(##"{ "appearance": { "window": { "opacity": 2 } } }"##) }
  #expect(throws: ConfigFormatError.self) {
    try parse(##"{ "appearance": { "git": { "background": { "image": { "path": "a.png", "align": "lower_right" } } } } }"##)
  }
  #expect(throws: ConfigFormatError.self) {
    try parse(##"{ "appearance": { "git": { "background": { "image": { "path": "a.png", "max_width": 1.5 } } } } }"##)
  }
  #expect(throws: ConfigFormatError.self) { try parse(##"{ appearance: { local: { font: { family: 12 } } } }"##) }
  #expect(throws: ConfigFormatError.self) { try parse(##"{ appearance: { local: { font: { family: [] } } } }"##) }
}

@Test func backgroundMergesItemByItem() throws {
  let appearance = try parse(
    ##"""
    { appearance: {
      default: { background: { image: { path: "/tmp/a.png", align: "bottom_right" } } },
      ssh: { background: { color: "#102030" } },
      git: { background: { color: "#203040", image: null } },
      local: { background: { image: { opacity: 0.5 } } },
    } }
    """##
  ).appearance
  // default の画像に、タブの色が足される。
  let ssh = appearance.theme(.ssh).background
  #expect(ssh?.color?.rgb == Rgb(0x102030))
  #expect(ssh?.image?.path == "/tmp/a.png")
  #expect(ssh?.image?.align == .bottomRight)
  // null で、default の画像だけを消せる。
  let git = appearance.theme(.git).background
  #expect(git?.color?.rgb == Rgb(0x203040))
  #expect(git?.image == nil)
  // 画像の中の項目も1つずつ重なる（path は default のまま、opacity だけ変える）。
  let local = appearance.theme(.local).background?.image
  #expect(local?.path == "/tmp/a.png")
  #expect(local?.opacity == 0.5)
}

@Test func fontFamilyFallsBack() throws {
  // 上から探して、入っている最初のフォントを使う。
  let found = try parse(##"{ appearance: { window: { font: { family: ["NoSuchFont", "Menlo"] } } } }"##).appearance
  #expect(found.window.font.family == "Menlo")
  // どれもなければ SF Mono（family なし）にする。エラーにはせず、ほかの設定はそのまま。
  let missing = try parse(
    ##"{ appearance: { default: { font: { family: "NoSuchFont" } }, git: { accent: { color: "#123456" } } } }"##
  ).appearance
  #expect(missing.theme(.local).font.family == nil)
  #expect(missing.theme(.git).colors.accent == Rgb(0x123456))
  #expect(missing.missingFonts == ["NoSuchFont"])
}

@Test func gitStatusColors() throws {
  let colors = try parse(
    ##"{ appearance: { git: { status: { modified: { color: "#111111" }, conflict: { color: "#222222" } } } } }"##
  ).appearance.theme(.git).colors
  #expect(colors.gitStatus["modified"] == Rgb(0x111111))
  #expect(colors.gitStatus["conflict"] == Rgb(0x222222))
  #expect(colors.gitStatus["deleted"] == nil)
  #expect(throws: ConfigFormatError.self) { try parse(##"{ appearance: { git: { status: { changed: { color: "#111111" } } } } }"##) }
  // 競合はどの種類も conflict、ほかは表示の名前の空白を _ にしたもの。
  #expect(GitStatusLine(.file, "a", label: "both mod", section: "unmerged").statusKey == "conflict")
  #expect(GitStatusLine(.file, "a", label: "new file", section: "staged").statusKey == "new_file")
}

@Test func gitSectionStyles() throws {
  let colors = try parse(
    ##"{ appearance: { git: { sections: { untracked: { color: "#111111", bold: false, underline: true } } } } }"##
  ).appearance.theme(.git).colors
  #expect(colors.gitSectionColor["untracked"] == Rgb(0x111111))
  #expect(colors.gitSectionBold["untracked"] == false)
  #expect(colors.gitSectionUnderline["untracked"] == true)
  #expect(colors.gitSectionColor["staged"] == nil)
  #expect(throws: ConfigFormatError.self) { try parse(##"{ appearance: { git: { sections: { staged: { bold: "yes" } } } } }"##) }
  #expect(throws: ConfigFormatError.self) { try parse(##"{ appearance: { git: { sections: { changes: { bold: true } } } } }"##) }
}

@Test func gitStatusBlankLineBeforeEachSection() {
  let status = parseGitStatus("## main\0 M a.txt\0?? b.txt\0")
  let lines = gitStatusLines(status)
  let texts = lines.map { $0.kind == .note && $0.text.isEmpty ? "" : $0.text }
  // ブランチ名の直後には空行を入れず、見出しの前に1行ずつ空ける。
  let branch = lines.firstIndex { $0.kind == .branch }!
  #expect(texts[branch + 1] == "")
  #expect(texts[branch + 2] == "not staged")
  #expect(texts[branch + 3] == "a.txt")
  #expect(texts[branch + 4] == "")
  #expect(texts[branch + 5] == "untracked")
}

@Test func locationColorPerTab() throws {
  let appearance = try parse(##"{ appearance: { git: { location: { color: "#123456" } } } }"##).appearance
  #expect(appearance.theme(.git).colors.location == Rgb(0x123456))
  // 書かなければ、補足の文字より暗い初期値。
  #expect(appearance.theme(.local).colors.location == Rgb(0x6B7382))
}

@Test func statusbarColor() throws {
  #expect(try parse("{}").appearance.window.colors.statusbar == Rgb(0x5CD8FF))
  #expect(try parse(##"{ appearance: { window: { statusbar: { color: "#123456" } } } }"##).appearance.window.colors.statusbar == Rgb(0x123456))
}

@Test func headerBackground() throws {
  #expect(try parse("{}").appearance.window.colors.header == nil)
  #expect(try parse(##"{ appearance: { window: { header: { background: { color: "#000000" } } } } }"##).appearance.window.colors.header == Rgb(0))
}

@Test func apparentSizeCountsFileSizes() async throws {
  let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("fm-ee2e-du-\(UUID().uuidString)")
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: dir) }
  try Data(count: 300_000).write(to: URL(fileURLWithPath: dir + "/a.bin"))
  try Data(count: 200_000).write(to: URL(fileURLWithPath: dir + "/b.bin"))
  let size = try #require(await apparentSize(dir))
  // du は KiB 単位に切り上げるので、ファイルの大きさの合計より少し大きい。
  #expect(size >= 500_000 && size < 520_000)
}

@Test func showUsedOption() throws {
  #expect(try parse("{}").appearance.theme(.drive).showUsed)
  let off = try parse(##"{ appearance: { google_drive: { show_used: false } } }"##).appearance
  #expect(!off.theme(.drive).showUsed)
  #expect(off.theme(.icloud).showUsed)
  // google_drive と icloud にだけ書ける。
  #expect(throws: ConfigFormatError.self) { try parse(##"{ appearance: { local: { show_used: false } } }"##) }
  #expect(throws: ConfigFormatError.self) { try parse(##"{ appearance: { icloud: { show_used: "no" } } }"##) }
}

@Test func symlinkColorAndDetection() throws {
  #expect(try parse("{}").appearance.theme(.local).colors.symlink == Rgb(0x2EE0A8))
  #expect(try parse(##"{ appearance: { ssh: { files: { symlink: { color: "#123456" } } } } }"##).appearance.theme(.ssh).colors.symlink == Rgb(0x123456))
  let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("fm-ee2e-link-\(UUID().uuidString)")
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: dir) }
  try Data().write(to: URL(fileURLWithPath: dir + "/target"))
  try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: "target")
  #expect(lstatPath(dir + "/link").type == .link)
  #expect(lstatPath(dir + "/target").type == .file)
}

@Test func languageSetting() throws {
  #expect(try parse("{}").language == "ja")
  #expect(try parse(##"{ language: "en" }"##).language == "en")
  #expect(try parse(##"{ language: "fr" }"##).language == "fr")
  #expect(throws: ConfigFormatError.self) { try parse(##"{ language: "../ja" }"##) }
  #expect(throws: ConfigFormatError.self) { try parse("{ language: 1 }") }
}
