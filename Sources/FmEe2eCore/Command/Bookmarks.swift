import Foundation

/// よく使うコマンドのブックマーク（B）。どのタブ・どの接続先でも同じ一覧を使う。
struct CommandBookmark: Equatable {
  /// 一覧に出す名前。空ならコマンドだけを出す。
  var name: String
  var command: String
}

/// ブックマークを ~/.config/fm-ee2e/bookmarks.json5 に読み書きする（このアプリが書くので、config.json5 とは分ける）。
/// 読むたびにファイルから読み直す（ほかの窓で書き換えても合う）。
enum CommandBookmarks {
  static var file: String { p.join(homeDir, ".config", "fm-ee2e", "bookmarks.json5") }

  /// 書いた順。ファイルがなければ空。
  static func load() throws -> [CommandBookmark] {
    guard let data = FileManager.default.contents(atPath: file), !String(decoding: data, as: UTF8.self).allSatisfy(\.isWhitespace) else {
      return []
    }
    guard let root = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any],
      let list = root["bookmarks"] as? [[String: Any]]
    else {
      throw AppError(tr("bookmarks.invalid_file", ["file": file]))
    }
    return list.compactMap { item in
      guard let command = item["command"] as? String else { return nil }
      return CommandBookmark(name: item["name"] as? String ?? "", command: command)
    }
  }

  /// 中身にコマンドが入ることがあるので、自分だけが読めるようにする。
  static func save(_ bookmarks: [CommandBookmark]) throws {
    try FileManager.default.createDirectory(atPath: p.dirname(file), withIntermediateDirectories: true)
    let value: [String: Any] = ["bookmarks": bookmarks.map { ["name": $0.name, "command": $0.command] }]
    try Data(json5Text(value).utf8).write(to: URL(fileURLWithPath: file), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
  }

  /// [command] を最後に足す。同じコマンドがもうあれば足さない。
  static func add(_ command: String) throws {
    var list = try load()
    if !list.contains(where: { $0.command == command }) {
      list.append(CommandBookmark(name: "", command: command))
      try save(list)
    }
  }
}

/// ブックマークの一覧（B）。↑↓ で選び、Enter でそのコマンドを Shell の入力欄に入れ、E で名前とコマンドを直し、D で消す。
final class BookmarkListDialog: Modal {
  enum Choice {
    case run(Int)
    case edit(Int)
    case delete(Int)
  }

  init(_ bookmarks: [CommandBookmark], index: Int, _ close: @escaping (Choice?) -> Void) {
    self.bookmarks = bookmarks
    self.close = close
    self.index = min(max(index, 0), bookmarks.count - 1)
    super.init(tr("bookmarks.title"))
  }

  let bookmarks: [CommandBookmark]
  let close: (Choice?) -> Void
  private var index: Int
  private var scroll = 0

  override func preferredWidth(_ screen: Screen) -> Int { min(screen.width - 4, 100) }

  override func bodyHeight(_ innerWidth: Int) -> Int { bookmarks.count }

  /// 名前があれば名前を左に出し、コマンドをその右に薄く出す。名前がなければコマンドだけ。
  override func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ innerWidth: Int) {
    let rows = max(1, bodyRows)
    scroll = fitScroll(cursor: index, scroll: scroll, length: bookmarks.count, rows: rows)
    let nameWidth = min(innerWidth / 3, (bookmarks.map { textWidth($0.name) }.max() ?? 0))
    for row in 0..<min(rows, bookmarks.count - scroll) {
      let i = scroll + row
      let bookmark = bookmarks[i]
      let selected = i == index
      let style = background.copyWith(bg: selected ? Palette.selected : Palette.surfaceHigh, bold: selected)
      screen.fill(x, y + row, innerWidth, 1, style)
      var col = x + 1
      if nameWidth > 0 {
        screen.text(col, y + row, truncate(bookmark.name, nameWidth), style)
        col += nameWidth + 2
      }
      screen.text(col, y + row, truncate(bookmark.command, max(0, x + innerWidth - col)), style.copyWith(fg: bookmark.name.isEmpty ? Palette.text : Palette.muted))
    }
  }

  override var hints: [(String, String)] {
    [("↑↓", tr("dialogs.hint.select")), ("Enter", tr("bookmarks.hint_run")), ("E", tr("bookmarks.hint_edit")),
      ("D", tr("bookmarks.hint_delete")), ("Esc", tr("dialogs.cancel"))]
  }

  override func handleKey(_ key: Key) {
    switch key.name {
    case "escape":
      close(nil)
    case "enter":
      close(.run(index))
    case "up":
      index = (index + bookmarks.count - 1) % bookmarks.count
    case "down":
      index = (index + 1) % bookmarks.count
    case "pageUp":
      index = max(0, index - max(1, bodyRows))
    case "pageDown":
      index = min(bookmarks.count - 1, index + max(1, bodyRows))
    case "home":
      index = 0
    case "end":
      index = bookmarks.count - 1
    case "char" where key.isLetter("e"):
      close(.edit(index))
    case "char" where key.isLetter("d"):
      close(.delete(index))
    default:
      break
    }
  }
}

/// ブックマークの名前とコマンドを直す小窓。↑↓・Tab で行を移り、Enter で決め、Esc でやめる。
final class BookmarkEditDialog: Modal {
  init(_ bookmark: CommandBookmark, _ close: @escaping (CommandBookmark?) -> Void) {
    self.close = close
    fields = [InputField(initial: bookmark.name), InputField(initial: bookmark.command)]
    super.init(tr("bookmarks.edit_title"))
  }

  let close: (CommandBookmark?) -> Void
  /// 名前・コマンド。
  private let fields: [InputField]
  private var row = 0
  private var error: String?

  override var focusedField: InputField? { fields[row] }

  override func preferredWidth(_ screen: Screen) -> Int { min(screen.width - 4, 100) }

  /// 2行と、エラーの行。
  override func bodyHeight(_ innerWidth: Int) -> Int { error == nil ? 2 : 4 }

  override func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ innerWidth: Int) {
    let labels = [tr("bookmarks.name"), tr("bookmarks.command")]
    let labelWidth = min(innerWidth / 3, (labels.map(textWidth).max() ?? 0) + 2)
    let valueWidth = max(0, innerWidth - labelWidth)
    for (index, label) in labels.enumerated() {
      let selected = index == row
      screen.text(x, y + index, truncate(label, labelWidth), background.copyWith(fg: selected ? Palette.text : Palette.muted, bold: selected))
      fields[index].draw(screen, x + labelWidth, y + index, valueWidth, focused: selected)
    }
    if let error {
      screen.text(x, y + 3, truncate(error, innerWidth), background.copyWith(fg: Palette.error))
    }
  }

  override var hints: [(String, String)] {
    [("↑↓", tr("dialogs.hint.move")), ("Enter", tr("dialogs.hint.decide")), ("Esc", tr("dialogs.cancel"))]
  }

  override func handleKey(_ key: Key) {
    switch key.name {
    case "escape":
      close(nil)
    case "enter":
      let command = fields[1].value.trimmingCharacters(in: .whitespaces)
      if command.isEmpty {
        error = tr("bookmarks.command_required")
        return
      }
      close(CommandBookmark(name: fields[0].value.trimmingCharacters(in: .whitespaces), command: command))
    case "up", "down", "tab", "backTab":
      row = 1 - row
    default:
      if fields[row].handleKey(key) {
        error = nil
      }
    }
  }
}

/// B。ブックマークの一覧を出し、選んだコマンドを、選んでいるタブの Shell（S）の入力欄に入れて開く。
final class BookmarksCommand: Command {
  init(_ shell: ShellCommand) {
    self.shell = shell
  }

  /// 選んでいるタブの S のコマンド。
  let shell: ShellCommand

  override var label: String { "Bookmark" }

  override var needsReady: Bool { false }

  override func run(_ c: CommandContext) async {
    var index = 0
    while true {
      let bookmarks: [CommandBookmark]
      do {
        bookmarks = try CommandBookmarks.load()
      } catch {
        await c.app.showError(error)
        return
      }
      if bookmarks.isEmpty {
        c.app.showStatus(tr("bookmarks.empty"))
        return
      }
      let start = index
      guard let choice: BookmarkListDialog.Choice = await c.app.showModal({ close in BookmarkListDialog(bookmarks, index: start, close) }) else {
        return
      }
      do {
        switch choice {
        case .run(let i):
          await shell.run(c, initial: bookmarks[i].command)
          return
        case .edit(let i):
          index = i
          let current = bookmarks[i]
          guard let edited: CommandBookmark = await c.app.showModal({ close in BookmarkEditDialog(current, close) }) else {
            continue
          }
          var list = bookmarks
          list[i] = edited
          try CommandBookmarks.save(list)
        case .delete(let i):
          index = i
          let bookmark = bookmarks[i]
          guard await c.app.confirm(tr("bookmarks.delete_title"), tr("bookmarks.delete_confirm", ["name": bookmark.name.isEmpty ? bookmark.command : bookmark.name])) else {
            continue
          }
          var list = bookmarks
          list.remove(at: i)
          try CommandBookmarks.save(list)
        }
      } catch {
        await c.app.showError(error)
        return
      }
    }
  }
}
