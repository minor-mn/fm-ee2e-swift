/// F12 の Get a new image で開く、Docker Hub で探すイメージの条件の小窓。↑↓・Tab で行を移り、文字はその行の入力欄に入る。
/// arch は ←→・Space で選ぶ。一番下は Search のボタン。Enter で決め、Esc でやめる。
final class ImageSearchDialog: Modal {
  struct Query: Equatable {
    var image = ""
    /// 空ならタグを絞らない。
    var tag = ""
    var architecture = ImageSearchDialog.architectures[0]
  }

  static let architectures = ["arm64", "amd64"]

  init(_ query: Query, _ close: @escaping (Query?) -> Void) {
    self.close = close
    image = InputField(initial: query.image)
    tag = InputField(initial: query.tag)
    architecture = Self.architectures.firstIndex(of: query.architecture) ?? 0
    super.init(tr("container.images.pull"))
  }

  let close: (Query?) -> Void
  private let image: InputField
  private let tag: InputField
  private var architecture: Int

  /// 0: イメージ名、1: タグ、2: arch、3: Search のボタン。
  private(set) var row = 0
  private static let architectureRow = 2
  private static let buttonRow = 3
  private static let rowCount = 4

  private func field(_ row: Int) -> InputField? {
    switch row {
    case 0: image
    case 1: tag
    default: nil
    }
  }

  override var focusedField: InputField? { field(row) }

  var result: Query {
    Query(image: image.value.trimmingCharacters(in: .whitespaces), tag: tag.value.trimmingCharacters(in: .whitespaces),
      architecture: Self.architectures[architecture])
  }

  override func preferredWidth(_ screen: Screen) -> Int { min(screen.width - 4, 80) }

  /// 3行・空行・ボタン。
  override func bodyHeight(_ innerWidth: Int) -> Int { 5 }

  override func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ innerWidth: Int) {
    let labels = ["image", "tag", "architecture"].map { tr("container.images.search_\($0)") }
    let labelWidth = min(innerWidth / 3, (labels.map(textWidth).max() ?? 0) + 2)
    let valueWidth = max(0, innerWidth - labelWidth)
    for (index, label) in labels.enumerated() {
      let rowY = y + index
      let selected = index == row
      screen.text(x, rowY, truncate(label, labelWidth), background.copyWith(fg: selected ? Palette.text : Palette.muted, bold: selected))
      if let field = field(index) {
        field.draw(screen, x + labelWidth, rowY, valueWidth, focused: selected)
        continue
      }
      // arch の選択肢。選んでいるものを括弧で囲む。
      var columnX = x + labelWidth
      for (choice, name) in Self.architectures.enumerated() {
        let chosen = choice == architecture
        let text = chosen ? "[\(name)]" : " \(name) "
        screen.text(columnX, rowY, text, background.copyWith(
          fg: chosen ? Palette.lime : Palette.muted, bg: chosen && selected ? Palette.selected : nil, bold: chosen))
        columnX += textWidth(text) + 1
      }
    }
    // ボタンは Containerfile の小窓の Create・Save と同じ形（[Search]、黄色の文字）。
    let selected = row == Self.buttonRow
    screen.text(x + labelWidth, y + labels.count + 1, truncate("[\(tr("container.images.search_button"))]", valueWidth), background.copyWith(
      fg: Palette.yellow, bg: selected ? Palette.selected : Palette.surfaceHigh, bold: selected))
  }

  override var hints: [(String, String)] {
    [("↑↓", tr("dialogs.hint.move")), ("←→", tr("dialogs.hint.toggle")), ("Enter", tr("dialogs.hint.apply")), ("Esc", tr("dialogs.cancel"))]
  }

  override func handleKey(_ key: Key) {
    switch key.name {
    case "escape":
      close(nil)
    case "enter":
      close(result)
    case "up", "backTab":
      row = (row + Self.rowCount - 1) % Self.rowCount
    case "down", "tab":
      row = (row + 1) % Self.rowCount
    case "right" where row == Self.architectureRow, "left" where row == Self.architectureRow,
      "char" where row == Self.architectureRow && key.char == " ":
      architecture = (architecture + 1) % Self.architectures.count
    default:
      _ = field(row)?.handleKey(key)
    }
  }
}
