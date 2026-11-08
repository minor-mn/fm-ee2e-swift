/// F12 の Create a new Containerfile / Modify the Containerfile で開く、Containerfile の項目の小窓。↑↓・Tab で行を移り、文字はその行の入力欄に入る。
/// Platform と元のイメージは選ぶ項目で、その行の Enter で一覧を開く（一覧は呼び出し側が出し、選んだら小窓を開き直す）。
/// 元のイメージは、Platform を選ぶまで選べない（その platform を持つローカルのイメージだけを出すため）。
/// 起動時のコマンドは ←→・Space で選び、「入力」を選んだときだけ下の行にコマンドを書ける。
/// 一番下は、新しく作るなら Create、すでにあるなら Save のボタン。ほかの行の Enter で決め、Esc でやめる。
final class ContainerfileDialog: Modal {
  enum Choice {
    case apply(ContainerfileSettings)
    /// Platform・元のイメージを一覧から選ぶ。それまでに入れた内容を持って閉じる。
    case choosePlatform(ContainerfileSettings)
    case chooseImage(ContainerfileSettings)
  }

  init(_ path: String, _ settings: ContainerfileSettings, isNew: Bool, row: Int = 0, _ close: @escaping (Choice?) -> Void) {
    self.path = path
    self.isNew = isNew
    self.close = close
    self.row = row
    platform = settings.platform
    image = settings.image
    fields = [
      InputField(initial: settings.packages.joined(separator: " ")),
      InputField(initial: settings.environment.joined(separator: " ")),
      InputField(initial: settings.timezone),
      InputField(initial: settings.language),
      InputField(initial: settings.charset),
      InputField(initial: settings.workdir),
      InputField(initial: settings.ports.joined(separator: " ")),
    ]
    switch settings.command {
    case .keepRunning: command = 0; customCommand = InputField()
    case .image: command = 1; customCommand = InputField()
    case .custom(let text): command = 2; customCommand = InputField(initial: text)
    }
    super.init("Containerfile")
    // 開き直したとき、飛ばす行に止まらないようにする。
    if skipped(self.row) { move(1) }
  }

  let path: String
  let isNew: Bool
  let close: (Choice?) -> Void
  private let platform: String
  private let image: String
  /// パッケージ・環境変数・タイムゾーン・言語・文字コード・作業フォルダー・ポート。
  private let fields: [InputField]
  private let customCommand: InputField
  /// 0: 動かし続ける、1: イメージのまま、2: 入力。
  private var command: Int

  /// 0: Platform、1: 元のイメージ、2〜8: [fields]、9: 起動時のコマンド、10: 入力するコマンド、11: Create・Save のボタン。
  private(set) var row: Int
  static let platformRow = 0
  static let imageRow = 1
  private static let packagesRow = 2
  private static let commandRow = 9
  private static let customRow = 10
  private static let buttonRow = 11
  private static let rowCount = 12

  private func field(_ row: Int) -> InputField? {
    if (Self.packagesRow..<(Self.packagesRow + fields.count)).contains(row) { return fields[row - Self.packagesRow] }
    return row == Self.customRow ? customCommand : nil
  }

  override var focusedField: InputField? { field(row) }

  /// パッケージを入れる道具。イメージを選ぶ前や、CentOS 7 以下のように入れられないイメージなら nil で、パッケージの行は空欄にして飛ばす。
  /// 欄の中身は残しておき、入れられるイメージを選び直せばまた出す（書き出すときは [Containerfile.text] が除く）。
  private var manager: PackageManager? { PackageManager.of(image) }

  /// 飛ばす行。Platform を選ぶ前の元のイメージ、「入力」を選んでいないときのコマンド、パッケージを入れられないときのパッケージ。
  private func skipped(_ row: Int) -> Bool {
    (row == Self.imageRow && platform.isEmpty) || (row == Self.customRow && command != 2) || (row == Self.packagesRow && manager == nil)
  }

  private func move(_ step: Int) {
    repeat {
      row = (row + Self.rowCount + step) % Self.rowCount
    } while skipped(row)
  }

  var result: ContainerfileSettings {
    func words(_ field: InputField) -> [String] { field.value.split(whereSeparator: \.isWhitespace).map(String.init) }
    func trimmed(_ field: InputField) -> String { field.value.trimmingCharacters(in: .whitespaces) }
    return ContainerfileSettings(
      platform: platform,
      image: image,
      packages: words(fields[0]),
      environment: words(fields[1]),
      timezone: trimmed(fields[2]),
      language: trimmed(fields[3]),
      charset: trimmed(fields[4]),
      workdir: trimmed(fields[5]),
      ports: words(fields[6]),
      command: [.keepRunning, .image, .custom(trimmed(customCommand))][command]
    )
  }

  private var labels: [String] {
    [tr("container.containerfile.platform"),
      tr("container.containerfile.image"),
      manager.map { tr("container.containerfile.packages", ["manager": $0.rawValue]) } ?? tr("container.containerfile.packages_none"),
      tr("container.containerfile.environment"),
      tr("container.containerfile.timezone"),
      tr("container.containerfile.language"),
      tr("container.containerfile.charset"),
      tr("container.containerfile.workdir"),
      tr("container.containerfile.ports"),
      tr("container.containerfile.command"),
      tr("container.containerfile.custom_command")]
  }

  override func preferredWidth(_ screen: Screen) -> Int { min(screen.width - 4, 110) }

  /// パス・空行・11行・空行・ボタン。
  override func bodyHeight(_ innerWidth: Int) -> Int { 15 }

  override func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ innerWidth: Int) {
    screen.text(x, y, truncate(path, innerWidth), background.copyWith(bold: true))
    let labels = labels
    let labelWidth = min(innerWidth / 3, (labels.map(textWidth).max() ?? 0) + 2)
    let valueWidth = max(0, innerWidth - labelWidth)
    for index in 0..<labels.count {
      let rowY = y + 2 + index
      let selected = index == row
      screen.text(x, rowY, truncate(labels[index], labelWidth), background.copyWith(fg: selected ? Palette.text : Palette.muted, bold: selected))
      if skipped(index) { continue }
      if let field = field(index) {
        field.draw(screen, x + labelWidth, rowY, valueWidth, focused: selected)
        continue
      }
      if index == Self.platformRow || index == Self.imageRow {
        // 選んだ値。まだなければ、Enter で選べることを薄く出す。
        let value = index == Self.platformRow ? platform : image
        let text = value.isEmpty ? tr("container.containerfile.choose_image") : value
        screen.text(x + labelWidth, rowY, truncate(text, valueWidth), background.copyWith(
          fg: value.isEmpty ? Palette.muted : Palette.text, bg: selected ? Palette.selected : nil, bold: selected && !value.isEmpty))
        continue
      }
      // 起動時のコマンドの選択肢。選んでいるものを括弧で囲む。
      var columnX = x + labelWidth
      for (choice, key) in ["keep_running", "image_default", "custom"].enumerated() {
        let chosen = choice == command
        let text = chosen ? "[\(tr("container.containerfile.\(key)"))]" : " \(tr("container.containerfile.\(key)")) "
        let width = min(textWidth(text), max(0, x + innerWidth - columnX))
        guard width > 0 else { break }
        screen.text(columnX, rowY, truncate(text, width), background.copyWith(
          fg: chosen ? Palette.lime : Palette.muted, bg: chosen && selected ? Palette.selected : nil, bold: chosen))
        columnX += width + 1
      }
    }
    // ボタンは入力欄の列に揃え、黄色の文字で出す。
    let selected = row == Self.buttonRow
    let button = "[\(tr(isNew ? "container.containerfile.create" : "container.containerfile.save"))]"
    screen.text(x + labelWidth, y + 2 + labels.count + 1, truncate(button, valueWidth), background.copyWith(
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
      switch row {
      case Self.platformRow: close(.choosePlatform(result))
      case Self.imageRow: close(.chooseImage(result))
      default: close(.apply(result))
      }
    case "up", "backTab":
      move(-1)
    case "down", "tab":
      move(1)
    case "right" where row == Self.commandRow, "char" where row == Self.commandRow && key.char == " ":
      command = (command + 1) % 3
    case "left" where row == Self.commandRow:
      command = (command + 2) % 3
    default:
      _ = field(row)?.handleKey(key)
    }
  }
}
