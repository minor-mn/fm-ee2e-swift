/// コンテナの作成設定を変える小窓（A）。↑↓ で行を移り、Tab で次の入力欄へ移る。文字はその入力欄に入る。
/// Rosetta は Space で切り替える。マウントはホスト側・ゲスト側・readonly（Space で切り替え）の3列で、最後の空行に書くと足せる。
/// ネットワークは選ぶ項目で、その行の Enter で一覧を開く（一覧は呼び出し側が出し、選んだら小窓を開き直す）。
/// ほかの行の Enter で決め、Esc でやめる。
/// Dockerfile・Containerfile から作るときは、一番上に元のイメージ（FROM）を書き換えられない行で出し、
/// その下の最初の行を、ビルドしてできるイメージの名前の入力欄にする。
final class ContainerSettingsDialog: Modal {
  enum Choice {
    case apply(ContainerSettings)
    /// ネットワークを一覧から選ぶ。それまでに入れた内容を持って閉じる。
    case chooseNetwork(ContainerSettings)
  }

  init(_ name: String, _ settings: ContainerSettings, baseImage: String? = nil, row: Int = 0, _ close: @escaping (Choice?) -> Void) {
    self.name = name
    self.close = close
    self.baseImage = baseImage
    self.row = row
    rosetta = settings.rosetta
    networks = settings.networks
    fields = [
      InputField(initial: settings.image),
      InputField(initial: settings.platform),
      InputField(initial: settings.cpus),
      InputField(initial: settings.memory),
      InputField(initial: settings.ports.joined(separator: " ")),
    ]
    mounts = settings.mounts.map { [InputField(initial: $0.source), InputField(initial: $0.target)] }
    // Apple Container の --volume で効くオプションは ro だけ（ほかは黙って無視される）なので、読み取り専用かだけを持つ。
    readonly = settings.mounts.map { $0.options.split(separator: ",").contains("ro") }
    super.init(tr("container.settings.title", ["name": name]))
    keepEmptyMount()
  }

  let name: String
  let close: (Choice?) -> Void
  /// Dockerfile・Containerfile の FROM のイメージ。あれば、一番上に書き換えられない行で出す（そのぶん下の行を1つずらす）。
  private let baseImage: String?
  private var offset: Int { baseImage == nil ? 0 : 1 }
  private let fields: [InputField]
  /// マウントの行ごとの、ホスト側・ゲスト側の入力欄と、読み取り専用か。最後の行はいつも空（足す用）。
  private var mounts: [[InputField]]
  private var readonly: [Bool]
  private var rosetta: Bool
  /// 選んだネットワーク（--network）。空なら default、["none"] ならネットワークなし。
  private let networks: [String]

  /// 0: イメージ、1: プラットフォーム、2: Rosetta、3: CPU、4: メモリ、5: ポート、6: ネットワーク、7〜: マウント。
  private(set) var row: Int
  /// マウントの行での列（0: ホスト側、1: ゲスト側、2: readonly）。
  private(set) var column = 0
  private static let fixedRows = 7
  private static let rosettaRow = 2
  static let networksRow = 6
  private var rowCount: Int { Self.fixedRows + mounts.count }

  private func field(_ row: Int, _ column: Int) -> InputField? {
    if row >= Self.fixedRows { return column < 2 ? mounts[row - Self.fixedRows][column] : nil }
    switch row {
    case 0, 1: return fields[row]
    case 3, 4, 5: return fields[row - 1]
    default: return nil
    }
  }

  override var focusedField: InputField? { field(row, column) }

  private func keepEmptyMount() {
    if mounts.last.map({ $0.contains { !$0.value.isEmpty } }) ?? true {
      mounts.append([InputField(), InputField()])
      readonly.append(false)
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
      networks: networks,
      mounts: zip(mounts, readonly).map { ContainerMount(source: trimmed($0.0[0]), target: trimmed($0.0[1]), options: $0.1 ? "ro" : "") }
        .filter { !($0.source.isEmpty && $0.target.isEmpty) }
    )
  }

  override func preferredWidth(_ screen: Screen) -> Int { min(screen.width - 4, 110) }

  /// 名前・空行・（元のイメージ）・7項目・空行・マウントの見出し・マウント・空行・注意書き。
  override func bodyHeight(_ innerWidth: Int) -> Int { 13 + offset + mounts.count }

  override func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ innerWidth: Int) {
    screen.text(x, y, truncate(name, innerWidth), background.copyWith(bold: true))
    var labels = Self.labels + [tr("container.info.mounts")]
    // ビルドして作るときは、最初の行がビルドしてできるイメージの名前になる。
    if baseImage != nil { labels[0] = tr("container.settings.build_image") }
    let labelWidth = min(innerWidth / 3, ((labels + [tr("container.settings.base_image")]).map(textWidth).max() ?? 0) + 2)
    let valueWidth = max(0, innerWidth - labelWidth)
    func label(_ text: String, _ rowY: Int, _ selected: Bool) {
      screen.text(x, rowY, truncate(text, labelWidth), background.copyWith(fg: selected ? Palette.text : Palette.muted, bold: selected))
    }
    if let baseImage {
      label(tr("container.settings.base_image"), y + 2, false)
      screen.text(x + labelWidth, y + 2, truncate(baseImage, valueWidth), background)
    }
    for index in 0..<Self.fixedRows {
      let rowY = y + 2 + offset + index
      let selected = index == row
      label(labels[index], rowY, selected)
      if let field = field(index, 0) {
        field.draw(screen, x + labelWidth, rowY, valueWidth, focused: selected)
      } else if index == Self.networksRow {
        let text = networks.isEmpty ? "default" : networks.joined(separator: " ")
        screen.text(x + labelWidth, rowY, truncate(text, valueWidth), background.copyWith(bg: selected ? Palette.selected : nil, bold: selected))
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
    let headerY = y + 2 + offset + Self.fixedRows + 1
    label(labels[Self.fixedRows], headerY, row >= Self.fixedRows)
    for (index, key) in ["mount_host", "mount_guest", "mount_readonly"].enumerated() where columns[index].1 > 0 {
      screen.text(columns[index].0, headerY, truncate(tr("container.settings.\(key)"), columns[index].1), background.copyWith(fg: Palette.muted))
    }
    for (index, fields) in mounts.enumerated() {
      let rowY = headerY + 1 + index
      for (col, field) in fields.enumerated() where columns[col].1 > 0 {
        field.draw(screen, columns[col].0, rowY, columns[col].1, focused: row == Self.fixedRows + index && column == col)
      }
      let checked = readonly[index]
      let selected = row == Self.fixedRows + index && column == 2
      screen.text(columns[2].0, rowY, checked ? "[x]" : "[ ]", background.copyWith(
        fg: checked ? Palette.lime : Palette.muted, bg: selected ? Palette.selected : Palette.surfaceHigh, bold: checked))
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
      close(row == Self.networksRow ? .chooseNetwork(result) : .apply(result))
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
    case "char" where row >= Self.fixedRows && column == 2 && key.char == " ":
      readonly[row - Self.fixedRows].toggle()
    default:
      _ = field(row, row >= Self.fixedRows ? column : 0)?.handleKey(key)
      keepEmptyMount()
    }
    if row < Self.fixedRows { column = 0 }
  }
}
