/// F12 の Networks で開く、ネットワークの小窓。
/// 既存のネットワークは、名前・アドレス・ネットマスクと、使っているコンテナを出すだけ（Apple Container には変更のコマンドがない）。
/// 使っているコンテナがなく、default でもなければ Delete のボタンを出し、Enter で消す（値を返す）。Esc で閉じる。
/// 新しく作るときは、名前・アドレス・ネットマスクの入力欄と Create のボタン。↑↓・Tab で行を移り、Enter で作り、Esc でやめる。
final class NetworkDialog: Modal {
  struct Values: Equatable {
    var name = ""
    var address = ""
    var netmask = ""
  }

  /// 新しく作る小窓。
  init(creating values: Values, _ close: @escaping (Values?) -> Void) {
    editable = true
    deletable = false
    containers = []
    self.close = close
    fields = [InputField(initial: values.name), InputField(initial: values.address), InputField(initial: values.netmask)]
    super.init(tr("container.networks.create"))
  }

  /// 既存のネットワークを見せる小窓。
  init(showing values: Values, containers: [String], _ close: @escaping (Values?) -> Void) {
    editable = false
    self.containers = containers
    // コンテナがついていると消せない。default は Apple Container が最初から持つもの。
    deletable = containers.isEmpty && values.name != "default"
    self.close = close
    fields = [InputField(initial: values.name), InputField(initial: values.address), InputField(initial: values.netmask)]
    super.init(values.name)
  }

  let editable: Bool
  let deletable: Bool
  let containers: [String]
  let close: (Values?) -> Void
  /// 名前・アドレス・ネットマスク。
  private let fields: [InputField]

  /// 0〜2: [fields]、3: Create のボタン（作るときだけ）。
  private(set) var row = 0
  private static let buttonRow = 3

  override var focusedField: InputField? { editable && row < fields.count ? fields[row] : nil }

  var result: Values {
    func trimmed(_ field: InputField) -> String { field.value.trimmingCharacters(in: .whitespaces) }
    return Values(name: trimmed(fields[0]), address: trimmed(fields[1]), netmask: trimmed(fields[2]))
  }

  private var labels: [String] { ["name", "address", "netmask", "containers"].map { tr("container.networks.\($0)") } }

  override func preferredWidth(_ screen: Screen) -> Int { min(screen.width - 4, 80) }

  /// 3項目・（見せるとき: 使っているコンテナ）・空行・ボタン（作るとき・消せるとき）。
  override func bodyHeight(_ innerWidth: Int) -> Int { editable ? 5 : 3 + max(1, containers.count) + (deletable ? 2 : 0) }

  override func drawBody(_ screen: Screen, _ x: Int, _ y: Int, _ innerWidth: Int) {
    let labels = labels
    let labelWidth = min(innerWidth / 3, (labels.map(textWidth).max() ?? 0) + 2)
    let valueWidth = max(0, innerWidth - labelWidth)
    for (index, field) in fields.enumerated() {
      let selected = editable && index == row
      screen.text(x, y + index, truncate(labels[index], labelWidth), background.copyWith(fg: selected ? Palette.text : Palette.muted, bold: selected))
      if editable {
        field.draw(screen, x + labelWidth, y + index, valueWidth, focused: selected)
      } else {
        screen.text(x + labelWidth, y + index, truncate(field.value, valueWidth), background)
      }
    }
    if editable {
      // ボタンは入力欄の列に揃え、ほかの小窓のボタンと同じく黄色の文字で出す。
      let selected = row == Self.buttonRow
      screen.text(x + labelWidth, y + fields.count + 1, truncate("[\(tr("container.networks.create_button"))]", valueWidth), background.copyWith(
        fg: Palette.yellow, bg: selected ? Palette.selected : Palette.surfaceHigh, bold: selected))
      return
    }
    // 使っているコンテナを1行ずつ出す。なければ「なし」。
    screen.text(x, y + fields.count, truncate(labels[3], labelWidth), background.copyWith(fg: Palette.muted))
    let names = containers.isEmpty ? [tr("container.networks.no_containers")] : containers
    for (index, name) in names.enumerated() {
      screen.text(x + labelWidth, y + fields.count + index, truncate(name, valueWidth), background.copyWith(fg: containers.isEmpty ? Palette.muted : Palette.text))
    }
    if deletable {
      screen.text(x + labelWidth, y + fields.count + names.count + 1, truncate("[\(tr("container.networks.delete_button"))]", valueWidth),
        background.copyWith(fg: Palette.yellow, bg: Palette.selected, bold: true))
    }
  }

  override var hints: [(String, String)] {
    if editable { return [("↑↓", tr("dialogs.hint.move")), ("Enter", tr("dialogs.hint.apply")), ("Esc", tr("dialogs.cancel"))] }
    if deletable { return [("Enter", tr("container.networks.delete_button")), ("Esc", tr("dialogs.hint.close"))] }
    return [("Enter", tr("dialogs.hint.close")), ("Esc", tr("dialogs.hint.close"))]
  }

  override func handleKey(_ key: Key) {
    guard editable else {
      if key.name == "escape" || (key.name == "enter" && !deletable) { close(nil) }
      // 消せるときの Enter は、消す（ネットワークの値を返す）。
      if key.name == "enter" && deletable { close(result) }
      return
    }
    switch key.name {
    case "escape":
      close(nil)
    case "enter":
      close(result)
    case "up", "backTab":
      row = (row + Self.buttonRow) % (Self.buttonRow + 1)
    case "down", "tab":
      row = (row + 1) % (Self.buttonRow + 1)
    default:
      if row < fields.count { _ = fields[row].handleKey(key) }
    }
  }

  /// ネットマスク（255.255.255.0 か 24）を、プレフィックスの長さにする。読めなければ nil。
  static func prefixLength(_ netmask: String) -> Int? {
    if let length = Int(netmask) { return (0...32).contains(length) ? length : nil }
    let parts = netmask.split(separator: ".").compactMap { UInt32($0) }
    guard parts.count == 4, parts.allSatisfy({ $0 <= 255 }) else { return nil }
    let value = parts.reduce(UInt32(0)) { ($0 << 8) | $1 }
    let length = value.nonzeroBitCount
    // 上から続けて 1 が並んでいるものだけ（255.0.255.0 などは読めない）。
    return value == (length == 0 ? 0 : UInt32.max << (32 - length)) ? length : nil
  }

  /// プレフィックスの長さを、255.255.255.0 の形にする。
  static func netmask(_ length: Int) -> String {
    let value = length == 0 ? UInt32(0) : UInt32.max << (32 - length)
    return [24, 16, 8, 0].map { String((value >> UInt32($0)) & 255) }.joined(separator: ".")
  }
}
