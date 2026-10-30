import AppKit

/// 見た目ごとの文字と、セルの大きさ。
final class FontSet {
  init(_ spec: FontSpec, zoom: Double) {
    let size = CGFloat(spec.size * zoom)
    regular = spec.family.flatMap { NSFont(name: $0, size: size) } ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    let converted = NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
    bold = converted == regular ? .monospacedSystemFont(ofSize: size, weight: .bold) : converted
    monospaced = regular.isFixedPitch
    cellWidth = ("M" as NSString).size(withAttributes: [.font: regular]).width
    ascent = CTFontGetAscent(regular)
    let descent = CTFontGetDescent(regular)
    cellHeight = (ascent + descent + max(0, CTFontGetLeading(regular))).rounded(.up)
    // 全角文字は、2つ分のセルの幅に合う大きさのヒラギノで描く（そのままだと字の間が空きすぎる）。
    let twoCells = cellWidth * 2
    func fitted(_ name: String, _ fallback: NSFont) -> NSFont {
      guard let base = NSFont(name: name, size: size) else { return fallback }
      let advance = ("あ" as NSString).size(withAttributes: [.font: base]).width
      return NSFont(name: name, size: min(size * 1.3, size * twoCells * 0.96 / advance)) ?? fallback
    }
    wide = fitted("HiraginoSans-W3", regular)
    wideBold = fitted("HiraginoSans-W6", bold)
  }

  let regular: NSFont
  let bold: NSFont

  /// 全角文字（2つ分のセル）に使う文字。
  let wide: NSFont
  let wideBold: NSFont

  /// 等幅のフォント。英数字を続けて描いても、セルの位置とずれない。
  let monospaced: Bool
  let cellWidth: CGFloat
  let cellHeight: CGFloat
  let ascent: CGFloat
}

/// GUI 版の窓。キー入力を端末と同じバイト列にして [KeyDecoder] に渡し、描いた画面を [GridView] に出す。
final class GuiHost: Host, GridSizer {
  init() {}

  private let decoder = KeyDecoder()
  private let resizeEvents = Broadcast<Void>()
  private var fontSets: [ThemeKey: FontSet] = [:]

  var keys: Broadcast<Key> { decoder.keys }
  var resizes: Broadcast<Void> { resizeEvents }

  /// 画面を描く view（窓を作ったときに決まる）。
  weak var view: GridView?

  /// 最後に描いた画面。
  private(set) var screen: Screen?

  var inputFilter: (([UInt8]) -> [UInt8])?

  /// 文字の大きさの倍率（⌘+・⌘-）。
  var zoom = 1.0 {
    didSet {
      fontSets.removeAll()
      view?.fontsChanged()
    }
  }

  var width: Int { view?.columns ?? 80 }
  var height: Int { view?.rows ?? 24 }
  var sizer: GridSizer? { self }

  /// 見た目（[Appearance.current]）が変わった。文字を作り直し、すべて描き直す。
  func appearanceChanged() {
    fontSets.removeAll()
    view?.appearanceChanged()
  }

  func fonts(_ key: ThemeKey) -> FontSet {
    if let found = fontSets[key] {
      return found
    }
    let made = FontSet(Appearance.current.theme(key).font, zoom: zoom)
    fontSets[key] = made
    return made
  }

  func gridSize(_ width: Int, _ height: Int, from: ThemeKey, to: ThemeKey) -> (Int, Int) {
    let outer = fonts(from)
    let inner = fonts(to)
    // 割り切れるはずの値が、小数の誤差で1つ少なくならないように少し足す。
    return (
      Int((CGFloat(width) * outer.cellWidth / inner.cellWidth + 0.001).rounded(.down)),
      Int((CGFloat(height) * outer.cellHeight / inner.cellHeight + 0.001).rounded(.down))
    )
  }

  func present(_ screen: Screen) {
    self.screen = screen
    view?.needsDisplay = true
  }

  /// 窓の大きさや文字の大きさが変わった。
  func resized() {
    resizeEvents.add(())
  }

  /// 端末と同じ形のキー入力のバイト列。枠の中の端末を使っていればそちらへ渡す。
  func send(_ bytes: [UInt8]) {
    if let inputFilter {
      let rest = inputFilter(bytes)
      if !rest.isEmpty {
        decoder.feed(rest)
      }
      return
    }
    decoder.feed(bytes)
  }
}
