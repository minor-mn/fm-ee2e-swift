/// キー入力。特殊キーは [name]、文字は [char]、Ctrl+英字は [ctrl] に英小文字、貼り付けは [paste]。
struct Key: CustomStringConvertible {
  private init(name: String, char: String? = nil, ctrl: String? = nil, paste: String? = nil) {
    self.name = name
    self.char = char
    self.ctrl = ctrl
    self.paste = paste
  }

  static func named(_ name: String) -> Key { Key(name: name) }
  static func char(_ char: String) -> Key { Key(name: "char", char: char) }
  static func ctrl(_ ctrl: String) -> Key { Key(name: "ctrl", ctrl: ctrl) }
  static func paste(_ paste: String) -> Key { Key(name: "paste", paste: paste) }

  let name: String
  let char: String?
  let ctrl: String?
  let paste: String?

  var isChar: Bool { char != nil }

  /// 英字は大文字・小文字を区別しない（FDと同じ）。
  func isLetter(_ letter: String) -> Bool { char != nil && char!.lowercased() == letter.lowercased() }

  var description: String { char ?? (ctrl != nil ? "Ctrl+\(ctrl!)" : name) }
}

/// 画面を出してキーを受け取るもの（窓）。
protocol Host: AnyObject {
  var keys: Broadcast<Key> { get }
  var resizes: Broadcast<Void> { get }

  /// 画面の桁数・行数（窓全体の見た目のセルで数える）。
  var width: Int { get }
  var height: Int { get }

  /// 組み込みシェルなどへ生の入力を渡す。返したバイトだけを通常のキーとして解釈する。
  var inputFilter: (([UInt8]) -> [UInt8])? { get set }

  /// 重ねる画面の大きさを決めるもの。見た目ごとに文字の大きさが変わらなければ nil。
  var sizer: GridSizer? { get }

  /// 描いた画面を出す。
  func present(_ screen: Screen)
}
