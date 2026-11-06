/// コンテナの作成設定を変える小窓（A）。↑↓ で行を移り、Tab で次の入力欄へ移る。文字はその入力欄に入る。
/// Rosetta は Space で切り替える。マウントはホスト側・ゲスト側・オプションの3列で、最後の空行に書くと足せる。
/// Enter で決め、Esc でやめる。
final class ContainerSettingsDialog: Modal {
  init(_ name: String, _ settings: ContainerSettings, _ close: @escaping (ContainerSettings?) -> Void) {
    self.name = name
    self.close = close
    rosetta = settings.rosetta
    fields = [
      InputField(initial: settings.image),
      InputField(initial: settings.platform),
      InputField(initial: settings.cpus),
      InputField(initial: settings.memory),
      InputField(initial: settings.ports.joined(separator: " ")),
      InputField(initial: settings.networks.joined(separator: " ")),
    ]
    mounts = settings.mounts.map { [InputField(initial: $0.source), InputField(initial: $0.target), InputField(initial: $0.options)] }
    super.init(tr("container.settings.title", ["name": name]))
    keepEmptyMount()
  }

  let name: String
  let close: (ContainerSettings?) -> Void
  private let fields: [InputField]
  /// マウントの行ごとの、ホスト側・ゲスト側・オプションの入力欄。最後の行はいつも空（足す用）。
  private var mounts: [[InputField]]
  private var rosetta: Bool

  /// 0: イメージ、1: プラットフォーム、2: Rosetta、3: CPU、4: メモリ、5: ポート、6: ネットワーク、7〜: マウント。
  private(set) var row = 0
  /// マウントの行での列（0: ホスト側、1: ゲスト側、2: オプション）。
  private(set) var column = 0
  private static let fixedRows = 7
  private static let rosettaRow = 2
  private var rowCount: Int { Self.fixedRows + mounts.count }

  private func field(_ row: Int, _ column: Int) -> InputField? {
    if row >= Self.fixedRows { return mounts[row - Self.fixedRows][column] }
    return row == Self.rosettaRow ? nil : fields[row < Self.rosettaRow ? row : row - 1]
  }

  override var focusedField: InputField? { field(row, column) }

  private func keepEmptyMount() {
    if mounts.last.map({ $0.contains { !$0.value.isEmpty } }) ?? true {
      mounts.append([InputField(), InputField(), InputField()])
    }
  }

  private static var labels: [String] {
    ["image", "platform", "rosetta", "cpus", "memory", "ports", "networks"].map { tr("container.info.\($0)") }
  }

  var result: ContainerSettings {
    func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
    func trimmed(_ field: InputField) -> String { field.value.trimmingCharacters(in: .whitespaces) }
    return ContainerSettings(
      image: trimmed(fields[0]),
      platform: trimmed(fields[1]),
      rosetta: rosetta,
      cpus: trimmed(fields[2]),
      memory: trimmed(fields[3]),
      ports: words(fields[4].value),
      networks: words(fields[5].value),
      mounts: mounts.map { ContainerMount(source: trimmed($0[0]), target: trimmed($0[1]), options: trimmed($0[2])) }.filter { !$0.isEmpty }
    )
  }

  override func preferredWidth(_ screen: Screen) -> Int { min(screen.width - 4, 110) }

  /// 名前・空行・7項目・空行・マウントの見出し・マウント・空行・注意書き。
  override func bodyHeight(_ innerWidth: Int) -> Int { 13 + mounts.count }

  override func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ innerWidth: Int) {
    screen.text(x, y, truncate(name, innerWidth), background.copyWith(bold: true))
    let labels = Self.labels + [tr("container.info.mounts")]
    let labelWidth = min(innerWidth / 3, (labels.map(textWidth).max() ?? 0) + 2)
    let valueWidth = max(0, innerWidth - labelWidth)
    func label(_ text: String, _ rowY: Int, _ selected: Bool) {
      screen.text(x, rowY, truncate(text, labelWidth), background.copyWith(fg: selected ? Palette.text : Palette.muted, bold: selected))
    }
    for index in 0..<Self.fixedRows {
      let rowY = y + 2 + index
      let selected = index == row
      label(labels[index], rowY, selected)
      if let field = field(index, 0) {
        field.draw(screen, x + labelWidth, rowY, valueWidth, focused: selected)
      } else {
        screen.text(x + labelWidth, rowY, rosetta ? "[x]" : "[ ]", background.copyWith(
          fg: rosetta ? Palette.lime : Palette.muted, bg: selected ? Palette.selected : Palette.surfaceHigh, bold: rosetta))
      }
    }
    // マウントは、ホスト側・ゲスト側・オプションを列に分ける（間を1文字空ける）。
    let optionWidth = min(8, valueWidth / 6)
    let hostWidth = max(0, (valueWidth - optionWidth - 2) * 3 / 5)
    let guestWidth = max(0, valueWidth - optionWidth - 2 - hostWidth)
    let columns = [(x + labelWidth, hostWidth), (x + labelWidth + hostWidth + 1, guestWidth), (x + labelWidth + hostWidth + guestWidth + 2, optionWidth)]
    let headerY = y + 2 + Self.fixedRows + 1
    label(labels[Self.fixedRows], headerY, row >= Self.fixedRows)
    for (index, key) in ["mount_host", "mount_guest", "mount_options"].enumerated() where columns[index].1 > 0 {
      screen.text(columns[index].0, headerY, truncate(tr("container.settings.\(key)"), columns[index].1), background.copyWith(fg: Palette.muted))
    }
    for (index, fields) in mounts.enumerated() {
      let rowY = headerY + 1 + index
      for (col, field) in fields.enumerated() where columns[col].1 > 0 {
        field.draw(screen, columns[col].0, rowY, columns[col].1, focused: row == Self.fixedRows + index && column == col)
      }
    }
    screen.text(x, headerY + mounts.count + 2, truncate(tr("container.settings.note"), innerWidth), background.copyWith(fg: Palette.muted))
  }

  override var hints: [(String, String)] {
    [("↑↓", tr("dialogs.hint.move")), ("Tab", tr("container.settings.next_field")), ("Space", tr("dialogs.hint.toggle")),
      ("Enter", tr("dialogs.hint.apply")), ("Esc", tr("dialogs.cancel"))]
  }

  override func handleKey(_ key: Key) {
    switch key.name {
    case "escape":
      close(nil)
    case "enter":
      close(result)
    case "up":
      row = (row + rowCount - 1) % rowCount
    case "down":
      row = (row + 1) % rowCount
    case "tab":
      // マウントの行では列を進め、最後の列から次の行へ移る。
      if row >= Self.fixedRows && column < 2 { column += 1 } else { column = 0; row = (row + 1) % rowCount }
    case "backTab":
      if row >= Self.fixedRows && column > 0 { column -= 1 } else {
        row = (row + rowCount - 1) % rowCount
        column = row >= Self.fixedRows ? 2 : 0
      }
    case "char" where row == Self.rosettaRow && key.char == " ":
      rosetta.toggle()
    default:
      _ = field(row, row >= Self.fixedRows ? column : 0)?.handleKey(key)
      keepEmptyMount()
    }
    if row < Self.fixedRows { column = 0 }
  }
}
