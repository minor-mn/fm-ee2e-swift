import AppKit

/// 描いた画面（[Screen]）を、セルの格子として描く view。キー入力・日本語入力・範囲選択も受け持つ。
///
/// 描く順は、窓全体の背景、窓全体の画面、重ねた画面（後のものほど上）。重ねた画面は、その範囲（ダイアログは書いたセル）を
/// いったん透明にしてから窓全体の背景とタブの背景を塗り直すので、下の文字は見えず、背景の透明度も二重にならない。
/// 地の色が、その画面の見た目の地の色と同じセルは塗らない（背景を見せる）。
final class GridView: NSView, NSTextInputClient {
  init(_ host: GuiHost) {
    self.host = host
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:)") }

  private unowned let host: GuiHost

  /// 窓全体の見た目のセルで数えた桁数・行数。
  private(set) var columns = 80
  private(set) var rows = 24

  /// 窓の端と格子の間。
  private let padding: CGFloat = 6

  /// 日本語入力の変換中の文字。
  private var markedText = ""

  /// カーソルの位置（変換の候補の窓を出す位置）。
  private var cursorRect: CGRect?

  /// マウスで選んでいる範囲。[target] の、画面から流れた行も含めて上から数えた行と、桁で数える。
  private struct Selection {
    /// 枠の中の端末など、自分で中身を持つもの（画面から流れた行も選べる）。
    weak var source: SelectionSource?

    /// それ以外の画面の文字（見えている分だけ）。
    var text: ScreenText?

    var target: SelectionSource? { text ?? source }
    var anchor: (x: Int, line: Int)
    var head: (x: Int, line: Int)
  }

  /// 画面に見えている文字を、範囲選択の中身として扱う。画面は描くたびに作り直すので、重ね方の位置（[path]）で探す。
  final class ScreenText: SelectionSource {
    init(_ path: [Int], _ view: GridView) {
      self.path = path
      self.view = view
    }

    let path: [Int]
    private weak var view: GridView?

    var screen: Screen? { view?.screen(at: path) }
    var lineCount: Int { screen?.height ?? 0 }
    var firstVisibleLine: Int { 0 }

    func lineCells(_ line: Int) -> (cells: [String], continues: Bool) {
      guard let screen, line >= 0, line < screen.height else { return ([], false) }
      return ((0..<screen.width).map { screen.cell($0, line)?.text ?? " " }, false)
    }

    func scrollLines(_ delta: Int) {}
  }

  /// 重ね方の位置 [path]（重ねた画面の番号を上からたどったもの）の画面。
  fileprivate func screen(at path: [Int]) -> Screen? {
    var current = host.screen
    for index in path {
      guard let layers = current?.layers, index < layers.count else { return nil }
      current = layers[index].screen
    }
    return current
  }

  private var selection: Selection?

  /// 選びながら選べる画面の上下の外にマウスを出している間、流れた行のほうへ動かし続けるタイマー。
  private var autoscroll: PeriodicTimer?

  /// 最後にドラッグした位置（[autoscroll] で使う）。
  private var dragPoint: CGPoint?

  /// トラックパッドの少しずつのスクロールの、まだ1行にならない分。
  private var scrollRemainder: CGFloat = 0

  private var backgroundImages: [String: NSImage] = [:]

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// 格子の左上（タイトルバーの下）。
  private var gridOrigin: CGPoint { CGPoint(x: padding, y: max(safeAreaInsets.top, padding)) }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateGrid()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateGrid()
  }

  /// 文字の大きさが変わった。
  func fontsChanged() {
    updateGrid(force: true)
  }

  /// 見た目が変わった。背景画像は読み直す（同じパスで中身を差し替えたときのため）。
  func appearanceChanged() {
    backgroundImages.removeAll()
    updateGrid(force: true)
  }

  private func updateGrid(force: Bool = false) {
    let fonts = host.fonts(.window)
    let origin = gridOrigin
    let nextColumns = max(1, Int((bounds.width - origin.x - padding) / fonts.cellWidth))
    let nextRows = max(1, Int((bounds.height - origin.y - padding) / fonts.cellHeight))
    if force || nextColumns != columns || nextRows != rows {
      columns = nextColumns
      rows = nextRows
      host.resized()
    }
    needsDisplay = true
  }

  // ---- 描画 ----

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.clear(bounds)
    paintWindowBackground(context)
    cursorRect = nil
    guard let screen = host.screen else { return }
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    drawScreen(context, screen, gridOrigin)
    drawSelection(context)
    drawCursor(context)
  }

  /// 窓全体の背景。不透明度（appearance.window.opacity）をかける。
  private func paintWindowBackground(_ context: CGContext) {
    if let background = Appearance.current.window.background {
      paint(context, background, bounds, Appearance.current.opacity)
    }
  }

  /// [frame] に背景を塗る。グラデーションと画像は [frame] に合わせて置く。
  private func paint(_ context: CGContext, _ background: Background, _ frame: CGRect, _ opacity: Double) {
    if let color = background.color {
      context.setFillColor(color.rgb.cgColor(color.alpha * opacity))
      context.fill(frame)
    }
    if let gradient = background.gradient,
      let made = NSGradient(starting: gradient.from.rgb.nsColor(gradient.from.alpha * opacity), ending: gradient.to.rgb.nsColor(gradient.to.alpha * opacity))
    {
      made.draw(in: frame, angle: CGFloat(gradient.angle))
    }
    if let image = background.image, let loaded = backgroundImage(image.path) {
      drawImage(
        context, loaded, image.mode, frame, image.opacity * opacity,
        align: image.align, maxWidth: image.maxWidth, maxHeight: image.maxHeight
      )
    }
  }

  private func backgroundImage(_ path: String) -> NSImage? {
    if let found = backgroundImages[path] {
      return found
    }
    let loaded = NSImage(contentsOfFile: path)
    backgroundImages[path] = loaded ?? NSImage()
    return loaded
  }

  /// [image] を [frame] に [mode] で置く。fit と center では、[frame] の幅・高さの [maxWidth]・[maxHeight] の割合を
  /// 上限に縮め（center は元の大きさより大きくしない）、[align] の位置に置く。
  private func drawImage(
    _ context: CGContext, _ image: NSImage, _ mode: ImageMode, _ frame: CGRect, _ opacity: Double,
    align: ImageAlign = .center, maxWidth: Double = 1, maxHeight: Double = 1
  ) {
    let size = image.size
    if size.width <= 0 || size.height <= 0 {
      return
    }
    context.saveGState()
    context.clip(to: frame)
    func draw(_ rect: CGRect) {
      image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: CGFloat(opacity), respectFlipped: true, hints: nil)
    }
    /// 大きさ [w]・[h] の画像を、[align] の位置に置く。
    func place(_ w: CGFloat, _ h: CGFloat) {
      let (fx, fy) = align.factors
      draw(CGRect(x: frame.minX + (frame.width - w) * fx, y: frame.minY + (frame.height - h) * fy, width: w, height: h))
    }
    let limitX = frame.width * maxWidth / size.width
    let limitY = frame.height * maxHeight / size.height
    switch mode {
    case .fill:
      let scale = max(frame.width / size.width, frame.height / size.height)
      place(size.width * scale, size.height * scale)
    case .fit:
      let scale = min(limitX, limitY)
      place(size.width * scale, size.height * scale)
    case .center:
      let scale = min(1, limitX, limitY)
      place(size.width * scale, size.height * scale)
    case .tile:
      var y = frame.minY
      while y < frame.maxY {
        var x = frame.minX
        while x < frame.maxX {
          draw(CGRect(x: x, y: y, width: size.width, height: size.height))
          x += size.width
        }
        y += size.height
      }
    }
    context.restoreGState()
  }

  /// [rect] の下にあるものを消し、窓全体の背景（と見た目 [theme] のタブの背景を [frame] に合わせて）を塗り直す。
  /// タブの背景は [frame] の中だけに塗り、[frame] に合わせて置く（枠のある画面は、枠の線の内側）。
  /// [fill] があれば、タブの背景の代わりにその色を [frame] に塗る。
  private func knockOut(_ context: CGContext, _ rect: CGRect, _ theme: ThemeKey, _ frame: CGRect, fill: Rgb? = nil) {
    context.saveGState()
    context.clip(to: rect)
    context.clear(rect)
    paintWindowBackground(context)
    if let fill {
      let alpha = Appearance.current.theme(theme).colors.alphas[fill.value] ?? 1
      context.setFillColor(fill.cgColor(alpha * Appearance.current.opacity))
      context.fill(frame)
    } else if theme != .window, let background = Appearance.current.theme(theme).background {
      context.clip(to: frame)
      paint(context, background, frame, Appearance.current.opacity)
    }
    context.restoreGState()
  }

  /// 画面 [screen] を、左上 [origin] から描き、重ねた画面を上に描く。
  private func drawScreen(_ context: CGContext, _ screen: Screen, _ origin: CGPoint) {
    let fonts = host.fonts(screen.theme)
    let colors = Appearance.current.theme(screen.theme).colors
    let base = colors.background
    let cw = fonts.cellWidth
    let ch = fonts.cellHeight
    let scale = window?.backingScaleFactor ?? 2
    func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
    func cellRect(_ x: Int, _ y: Int, _ w: Int = 1) -> CGRect {
      let left = snap(origin.x + CGFloat(x) * cw)
      let top = snap(origin.y + CGFloat(y) * ch)
      return CGRect(x: left, y: top, width: snap(origin.x + CGFloat(x + w) * cw) - left, height: snap(origin.y + CGFloat(y + 1) * ch) - top)
    }
    // 地の色（同じ色が続く分はまとめて塗る）。
    for y in 0..<screen.height {
      var x = 0
      while x < screen.width {
        guard let cell = screen.cell(x, y), cell.style.bg != base else {
          x += 1
          continue
        }
        var end = x + 1
        while end < screen.width, let next = screen.cell(end, y), next.style.bg == cell.style.bg {
          end += 1
        }
        let bg = cell.style.bg
        context.setFillColor(bg.cgColor((colors.alphas[bg.opaque.value] ?? 1) * bg.opacity))
        context.fill(cellRect(x, y, end - x))
        x = end
      }
    }
    // 文字。
    for y in 0..<screen.height {
      let baseline = origin.y + CGFloat(y) * ch + fonts.ascent + (ch - fonts.ascent - CTFontGetDescent(fonts.regular)) / 2
      var x = 0
      while x < screen.width {
        guard let cell = screen.cell(x, y), !cell.text.isEmpty else {
          x += 1
          continue
        }
        let style = cell.style
        let wide = x + 1 < screen.width && screen.cell(x + 1, y)?.text.isEmpty == true
        let rect = cellRect(x, y, wide ? 2 : 1)
        if let scalar = cell.text.unicodeScalars.first, cell.text.unicodeScalars.count == 1, drawBlock(context, scalar, rect, style.fg) {
          x += 1
          continue
        }
        var text = cell.text
        var end = x + (wide ? 2 : 1)
        if fonts.monospaced && Self.isAscii(cell.text) {
          while end < screen.width, let next = screen.cell(end, y), next.style == style, Self.isAscii(next.text),
            !Self.isBlock(next.text)
          {
            text += next.text
            end += 1
          }
        }
        if text.contains(where: { $0 != " " }) {
          let font = wide ? (style.bold ? fonts.wideBold : fonts.wide) : (style.bold ? fonts.bold : fonts.regular)
          let line = Self.line(text, font, style.fg)
          var left = origin.x + CGFloat(x) * cw
          if !(fonts.monospaced && Self.isAscii(cell.text)) {
            // 英数字以外（全角文字など）は、セルの中央に置く。
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let space = CGFloat(end - x) * cw
            if width < space {
              left += (space - width) / 2
            }
          }
          context.textPosition = CGPoint(x: left, y: baseline)
          CTLineDraw(line, context)
        }
        if style.underline {
          context.setFillColor(style.fg.cgColor())
          let line = cellRect(x, y, end - x)
          context.fill(CGRect(x: line.minX, y: line.maxY - max(1, ch / 14) - 1, width: line.width, height: max(1, ch / 14)))
        }
        x = end
      }
    }
    if let image = screen.image {
      let frame = cellRect(image.x, image.y, image.w).union(cellRect(image.x, image.y + image.h - 1, image.w))
      drawImage(context, image.image, .fit, frame, 1)
    }
    for layer in screen.layers {
      let frame = cellRect(layer.x, layer.y, layer.w).union(cellRect(layer.x, layer.y + max(0, layer.h - 1), layer.w))
      let top = layer.screen
      if top.clear {
        // ダイアログは、書いたセルの分だけ下を隠す。
        let inner = host.fonts(top.theme)
        for y in 0..<top.height {
          var x = 0
          while x < top.width {
            guard top.cell(x, y) != nil else {
              x += 1
              continue
            }
            var end = x + 1
            while end < top.width && top.cell(end, y) != nil {
              end += 1
            }
            let left = snap(frame.minX + CGFloat(x) * inner.cellWidth)
            let topY = snap(frame.minY + CGFloat(y) * inner.cellHeight)
            let rect = CGRect(
              x: left, y: topY,
              width: snap(frame.minX + CGFloat(end) * inner.cellWidth) - left,
              height: snap(frame.minY + CGFloat(y + 1) * inner.cellHeight) - topY
            )
            knockOut(context, rect, top.theme, frame)
            x = end
          }
        }
      } else if layer.framed && top.width > 1 && top.height > 1 {
        // 枠の線はマスの中央に引くので、背景は線から線までに塗る（線の外へはみ出さない）。
        let inner = host.fonts(top.theme)
        let lines = CGRect(
          x: frame.minX + inner.cellWidth / 2, y: frame.minY + inner.cellHeight / 2,
          width: CGFloat(top.width - 1) * inner.cellWidth, height: CGFloat(top.height - 1) * inner.cellHeight
        )
        knockOut(context, frame, top.theme, lines, fill: layer.fill)
      } else {
        knockOut(context, frame, top.theme, frame)
      }
      drawScreen(context, top, frame.origin)
    }
  }

  private static func isAscii(_ text: String) -> Bool {
    let scalars = text.unicodeScalars
    return scalars.count == 1 && scalars.first!.value >= 0x20 && scalars.first!.value < 0x7f
  }

  private static func isBlock(_ text: String) -> Bool {
    guard let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1 else { return false }
    return blockShapes[scalar] != nil || "▀▄█▌▐".unicodeScalars.contains(scalar)
  }

  private static func line(_ text: String, _ font: NSFont, _ color: Rgb) -> CTLine {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor(),
    ]
    return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
  }

  /// 罫線の形。左・右・上・下に伸ばす線の太さ（0 なし、1 細い、2 太い）と、角を丸めるか。
  private static let blockShapes: [Unicode.Scalar: (l: Int, r: Int, u: Int, d: Int, round: Bool)] = [
    "─": (1, 1, 0, 0, false), "━": (2, 2, 0, 0, false), "│": (0, 0, 1, 1, false), "┃": (0, 0, 2, 2, false),
    "┌": (0, 1, 0, 1, false), "┐": (1, 0, 0, 1, false), "└": (0, 1, 1, 0, false), "┘": (1, 0, 1, 0, false),
    "╭": (0, 1, 0, 1, true), "╮": (1, 0, 0, 1, true), "╰": (0, 1, 1, 0, true), "╯": (1, 0, 1, 0, true),
    "├": (0, 1, 1, 1, false), "┤": (1, 0, 1, 1, false), "┬": (1, 1, 0, 1, false), "┴": (1, 1, 1, 0, false),
    "┼": (1, 1, 1, 1, false),
  ]

  /// 罫線とブロックは、フォントではなく線と四角で描く（行の間に隙間ができず、枠がつながる）。描いたら true。
  private func drawBlock(_ context: CGContext, _ scalar: Unicode.Scalar, _ rect: CGRect, _ color: Rgb) -> Bool {
    context.setFillColor(color.cgColor())
    switch scalar {
    case "█": context.fill(rect)
    case "▀": context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: (rect.height / 2).rounded()))
    case "▄":
      let h = (rect.height / 2).rounded()
      context.fill(CGRect(x: rect.minX, y: rect.maxY - h, width: rect.width, height: h))
    case "▌": context.fill(CGRect(x: rect.minX, y: rect.minY, width: (rect.width / 2).rounded(), height: rect.height))
    case "▐":
      let w = (rect.width / 2).rounded()
      context.fill(CGRect(x: rect.maxX - w, y: rect.minY, width: w, height: rect.height))
    default:
      guard let shape = Self.blockShapes[scalar] else { return false }
      let scale = window?.backingScaleFactor ?? 2
      let thin = max(1 / scale, (rect.height / 18 * scale).rounded() / scale)
      func weight(_ w: Int) -> CGFloat { w == 2 ? thin * 2 : thin }
      let cx = ((rect.midX) * scale).rounded() / scale
      let cy = ((rect.midY) * scale).rounded() / scale
      if shape.round {
        // 丸い角は、中心を通る弧でつなぐ。
        let radius = min(rect.width, rect.height) / 2
        let path = CGMutablePath()
        let horizontal = CGPoint(x: shape.l > 0 ? rect.minX : rect.maxX, y: cy)
        let vertical = CGPoint(x: cx, y: shape.u > 0 ? rect.minY : rect.maxY)
        path.move(to: horizontal)
        path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: vertical, radius: radius)
        path.addLine(to: vertical)
        context.saveGState()
        context.setStrokeColor(color.cgColor())
        context.setLineWidth(thin)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
        return true
      }
      if shape.l > 0 {
        let w = weight(shape.l)
        context.fill(CGRect(x: rect.minX, y: cy - w / 2, width: cx - rect.minX + w / 2, height: w))
      }
      if shape.r > 0 {
        let w = weight(shape.r)
        context.fill(CGRect(x: cx - w / 2, y: cy - w / 2, width: rect.maxX - cx + w / 2, height: w))
      }
      if shape.u > 0 {
        let w = weight(shape.u)
        context.fill(CGRect(x: cx - w / 2, y: rect.minY, width: w, height: cy - rect.minY + w / 2))
      }
      if shape.d > 0 {
        let w = weight(shape.d)
        context.fill(CGRect(x: cx - w / 2, y: cy - w / 2, width: w, height: rect.maxY - cy + w / 2))
      }
    }
    return true
  }

  /// 画面と重ねた画面をたどって、[visit] に画面とその左上を渡す（描いた順）。
  private func walk(
    _ screen: Screen, _ origin: CGPoint, _ source: SelectionSource?, _ visit: (Screen, CGPoint, SelectionSource?) -> Void
  ) {
    walkPaths(screen, origin, source, []) { s, point, source, _ in visit(s, point, source) }
  }

  /// [walk] と同じく、重ね方の位置（[screen(at:)] の path）も渡す。
  private func walkPaths(
    _ screen: Screen, _ origin: CGPoint, _ source: SelectionSource?, _ path: [Int],
    _ visit: (Screen, CGPoint, SelectionSource?, [Int]) -> Void
  ) {
    visit(screen, origin, source, path)
    let fonts = host.fonts(screen.theme)
    for (index, layer) in screen.layers.enumerated() {
      let point = CGPoint(x: origin.x + CGFloat(layer.x) * fonts.cellWidth, y: origin.y + CGFloat(layer.y) * fonts.cellHeight)
      walkPaths(layer.screen, point, layer.selection, path + [index], visit)
    }
  }

  /// カーソル。後に重ねた画面のものほど優先する。日本語入力の変換中の文字も、ここに出す。
  private func drawCursor(_ context: CGContext) {
    guard let screen = host.screen else { return }
    var found: (CGRect, FontSet)?
    walk(screen, gridOrigin, nil) { s, origin, _ in
      if let c = s.cursor {
        let fonts = host.fonts(s.theme)
        found = (
          CGRect(x: origin.x + CGFloat(c.x) * fonts.cellWidth, y: origin.y + CGFloat(c.y) * fonts.cellHeight, width: fonts.cellWidth, height: fonts.cellHeight),
          fonts
        )
      }
    }
    guard let (rect, fonts) = found else { return }
    cursorRect = rect
    let colors = Appearance.current.window.colors
    if markedText.isEmpty {
      context.setFillColor(colors.text.cgColor(0.6))
      context.fill(rect)
      return
    }
    let line = Self.line(markedText, fonts.regular, colors.text)
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    context.setFillColor(colors.surfaceHigh.cgColor())
    context.fill(CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height))
    context.textPosition = CGPoint(x: rect.minX, y: rect.minY + fonts.ascent)
    CTLineDraw(line, context)
    context.setFillColor(colors.text.cgColor())
    context.fill(CGRect(x: rect.minX, y: rect.maxY - 2, width: width, height: 1))
  }

  // ---- 範囲選択とコピー ----

  /// [point] の下にいちばん上に見えている画面と、その中身（自分で中身を持たない画面は [ScreenText]）・左上。
  /// ダイアログの透明なセルの下は、下の画面を選ぶ。
  private func selectable(at point: CGPoint) -> (SelectionSource, Screen, CGPoint)? {
    guard let screen = host.screen else { return nil }
    var found: (SelectionSource?, [Int], Screen, CGPoint)?
    walkPaths(screen, gridOrigin, nil, []) { s, origin, source, path in
      let (x, y) = cellAt(point, s, origin)
      if x >= 0 && y >= 0 && x < s.width && y < s.height && (!s.clear || s.cell(x, y) != nil) {
        found = (source, path, s, origin)
      }
    }
    guard let (source, path, s, origin) = found else { return nil }
    return (source ?? ScreenText(path, self), s, origin)
  }

  /// [source] を出している画面とその左上。今は出ていなければ nil。
  private func screenOf(_ source: SelectionSource) -> (Screen, CGPoint)? {
    guard let screen = host.screen else { return nil }
    let text = source as? ScreenText
    var found: (Screen, CGPoint)?
    walkPaths(screen, gridOrigin, nil, []) { s, origin, shown, path in
      if text.map({ $0.path == path }) ?? (shown === source) {
        found = (s, origin)
      }
    }
    return found
  }

  /// [point] の、画面 [s]（左上 [origin]）のセル。画面の外なら範囲外の値。
  private func cellAt(_ point: CGPoint, _ s: Screen, _ origin: CGPoint) -> (Int, Int) {
    let fonts = host.fonts(s.theme)
    return (
      Int(((point.x - origin.x) / fonts.cellWidth).rounded(.down)),
      Int(((point.y - origin.y) / fonts.cellHeight).rounded(.down))
    )
  }

  /// 選んでいる範囲の、行ごとの桁の範囲（読む順）。[to] が nil なら行の終わりまで。
  private func selectedRanges() -> [(line: Int, from: Int, to: Int?)] {
    guard let selection, let source = selection.target else { return [] }
    var start = selection.anchor
    var end = selection.head
    if (end.line, end.x) < (start.line, start.x) {
      swap(&start, &end)
    }
    let first = max(start.line, 0)
    let last = min(end.line, source.lineCount - 1)
    if first > last {
      return []
    }
    return (first...last).map { line in
      (line, line == start.line ? max(0, start.x) : 0, line == end.line ? end.x : nil)
    }
  }

  private func drawSelection(_ context: CGContext) {
    guard let source = selection?.target, let (screen, origin) = screenOf(source) else { return }
    let fonts = host.fonts(screen.theme)
    let top = source.firstVisibleLine
    context.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45).cgColor)
    for (line, from, to) in selectedRanges() {
      let y = line - top
      let last = min(to ?? screen.width - 1, screen.width - 1)
      if y < 0 || y >= screen.height || from > last {
        continue
      }
      context.fill(
        CGRect(
          x: origin.x + CGFloat(from) * fonts.cellWidth, y: origin.y + CGFloat(y) * fonts.cellHeight,
          width: CGFloat(last - from + 1) * fonts.cellWidth, height: fonts.cellHeight
        )
      )
    }
  }

  /// 選んでいる範囲の文字。端で折り返した行はつなぎ、そうでない行は右端の空白を除いて改行でつなぐ。
  private func selectedText() -> String? {
    guard let source = selection?.target else { return nil }
    let plain = source is ScreenText
    let ranges = selectedRanges()
    if ranges.isEmpty {
      return nil
    }
    var text = ""
    for (index, (line, from, to)) in ranges.enumerated() {
      let (cells, continues) = source.lineCells(line)
      let last = min(to ?? cells.count - 1, cells.count - 1)
      var part = from <= last ? cells[from...last].joined() : ""
      let joined = continues && to == nil
      if plain {
        // 画面の文字は、枠の罫線を除き、行の前後の空白も除く。
        part = String(String.UnicodeScalarView(part.unicodeScalars.map { (0x2500...0x257F).contains($0.value) ? " " : $0 }))
        part = part.trimmingCharacters(in: .whitespaces)
      } else if !joined {
        while part.hasSuffix(" ") {
          part.removeLast()
        }
      }
      text += part
      if index < ranges.count - 1 && !joined {
        text += "\n"
      }
    }
    return text
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if event.modifierFlags.contains(.command) {
      openLink(at: point)
      return
    }
    if let (source, s, origin) = selectable(at: point) {
      let (x, y) = cellAt(point, s, origin)
      let line = source.firstVisibleLine + y
      selection = Selection(source: source, text: source as? ScreenText, anchor: (x, line), head: (x, line))
    } else {
      selection = nil
    }
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    dragPoint = convert(event.locationInWindow, from: nil)
    extendSelection()
  }

  /// ドラッグしている位置まで選ぶ。選べる画面の上下の外なら、流れた行のほうへ動かしながら選ぶ。
  private func extendSelection() {
    guard var current = selection, let source = current.target, let point = dragPoint,
      let (screen, origin) = screenOf(source)
    else {
      stopAutoscroll()
      return
    }
    let (x, y) = cellAt(point, screen, origin)
    let outside = y < 0 ? -1 : (y >= screen.height ? 1 : 0)
    if outside != 0 {
      source.scrollLines(outside)
      if autoscroll == nil {
        autoscroll = PeriodicTimer(milliseconds: 50) { [weak self] in self?.extendSelection() }
      }
    } else {
      stopAutoscroll()
    }
    let row = min(max(y, 0), screen.height - 1)
    current.head = (min(max(x, 0), screen.width - 1), source.firstVisibleLine + row)
    selection = current
    needsDisplay = true
  }

  private func stopAutoscroll() {
    autoscroll?.cancel()
    autoscroll = nil
  }

  override func mouseUp(with event: NSEvent) {
    stopAutoscroll()
    dragPoint = nil
    // ドラッグせずにクリックしただけなら、そこのリンクを開く。
    if let current = selection, current.anchor == current.head {
      selection = nil
      needsDisplay = true
      openLink(at: convert(event.locationInWindow, from: nil))
    }
  }

  /// ホイール・トラックパッドで、枠の中の端末の流れた行をさかのぼる。
  override func scrollWheel(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard let (source, screen, _) = selectable(at: point) else { return }
    let lineHeight = host.fonts(screen.theme).cellHeight
    // 細かく届く（トラックパッド）ときは点で、そうでなければ1回で3行。
    scrollRemainder += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / lineHeight : event.scrollingDeltaY * 3
    let lines = Int(scrollRemainder.rounded(.towardZero))
    if lines != 0 {
      scrollRemainder -= CGFloat(lines)
      source.scrollLines(-lines)
    }
  }

  /// ⌘A で、枠の中の端末の出力（流れた行を含む）をすべて選ぶ。
  @objc override func selectAll(_ sender: Any?) {
    guard let screen = host.screen else { return }
    var found: SelectionSource?
    walk(screen, gridOrigin, nil) { _, _, source in
      if let source {
        found = source
      }
    }
    guard let source = found else { return }
    // 最後の、何も書いていない行は含めない。
    var last = source.lineCount - 1
    while last > 0 && source.lineCells(last).cells.allSatisfy({ $0 == " " || $0.isEmpty }) {
      last -= 1
    }
    selection = Selection(source: source, text: nil, anchor: (0, 0), head: (Int.max / 2, last))
    needsDisplay = true
  }

  /// クリック（⌘+クリックでも）で、リンク（git push のあとの URL など）を開く。
  private func openLink(at point: CGPoint) {
    if let link = link(at: point), let url = URL(string: link) {
      NSWorkspace.shared.open(url)
    }
  }

  /// [point] にあるリンク先。なければ nil。
  private func link(at point: CGPoint) -> String? {
    guard let screen = host.screen else { return nil }
    var link: String?
    walk(screen, gridOrigin, nil) { s, origin, _ in
      let fonts = host.fonts(s.theme)
      let x = Int(((point.x - origin.x) / fonts.cellWidth).rounded(.down))
      let y = Int(((point.y - origin.y) / fonts.cellHeight).rounded(.down))
      if x >= 0 && y >= 0 && x < s.width && y < s.height, let cell = s.cell(x, y) {
        link = cell.style.link
      }
    }
    return link
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas {
      removeTrackingArea(area)
    }
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
  }

  /// リンクの上では、指の形のカーソルにする。
  override func mouseMoved(with event: NSEvent) {
    if link(at: convert(event.locationInWindow, from: nil)) != nil {
      NSCursor.pointingHand.set()
    } else {
      NSCursor.arrow.set()
    }
  }

  @objc func copy(_ sender: Any?) {
    guard let text = selectedText() else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  /// 貼り付けは、端末と同じく bracketed paste の形で送る（改行は CR にする）。
  @objc func paste(_ sender: Any?) {
    guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
    host.send(Array("\u{1b}[200~".utf8) + Array(normalized.utf8) + Array("\u{1b}[201~".utf8))
  }

  @objc func zoomIn(_ sender: Any?) { host.zoom = min(host.zoom * 1.1, 4) }

  @objc func zoomOut(_ sender: Any?) { host.zoom = max(host.zoom / 1.1, 0.4) }

  @objc func zoomReset(_ sender: Any?) { host.zoom = 1 }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.firstResponder === self, event.modifierFlags.contains(.command) else {
      return super.performKeyEquivalent(with: event)
    }
    // ⌘+ は、キーボードによって ⌘= や ⌘; で届く。
    switch event.charactersIgnoringModifiers {
    case "+", "=", ";":
      zoomIn(nil)
    case "-":
      zoomOut(nil)
    case "0":
      zoomReset(nil)
    default:
      return super.performKeyEquivalent(with: event)
    }
    return true
  }

  // ---- キー入力 ----

  override func keyDown(with event: NSEvent) {
    if selection != nil {
      selection = nil
      needsDisplay = true
    }
    // 変換中は、確定・取り消しも日本語入力に任せる。
    if hasMarkedText() {
      interpretKeyEvents([event])
      return
    }
    if let bytes = Self.encode(event) {
      host.send(bytes)
      return
    }
    interpretKeyEvents([event])
  }

  /// 文字以外のキーと Ctrl+キーを、端末と同じバイト列にする。文字のキーは nil（日本語入力を通す）。
  private static func encode(_ event: NSEvent) -> [UInt8]? {
    let flags = event.modifierFlags
    if let special = specialKeys[event.keyCode] {
      if event.keyCode == 48 && flags.contains(.shift) {
        return Array("\u{1b}[Z".utf8)
      }
      return Array(special.utf8)
    }
    guard flags.contains(.control), let chars = event.charactersIgnoringModifiers?.lowercased(), let scalar = chars.unicodeScalars.first
    else {
      return nil
    }
    switch scalar {
    case "a"..."z": return [UInt8(scalar.value - 0x60)]
    case "[": return [27]
    case "\\": return [28]
    case "]": return [29]
    case "^", "6": return [30]
    case "_", "-", "/": return [31]
    case "@", " ", "2": return [0]
    default: return nil
    }
  }

  /// キーコードごとの、端末が送るバイト列。
  private static let specialKeys: [UInt16: String] = [
    36: "\r", 76: "\r", 48: "\t", 51: "\u{7f}", 53: "\u{1b}", 117: "\u{1b}[3~",
    123: "\u{1b}[D", 124: "\u{1b}[C", 125: "\u{1b}[B", 126: "\u{1b}[A",
    115: "\u{1b}[H", 119: "\u{1b}[F", 116: "\u{1b}[5~", 121: "\u{1b}[6~",
    122: "\u{1b}OP", 120: "\u{1b}OQ", 99: "\u{1b}OR", 118: "\u{1b}OS",
    96: "\u{1b}[15~", 97: "\u{1b}[17~", 98: "\u{1b}[18~", 100: "\u{1b}[19~",
    101: "\u{1b}[20~", 109: "\u{1b}[21~", 103: "\u{1b}[23~", 111: "\u{1b}[24~",
  ]

  // ---- 日本語入力（NSTextInputClient） ----

  func insertText(_ string: Any, replacementRange: NSRange) {
    let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    markedText = ""
    needsDisplay = true
    if !text.isEmpty {
      host.send(Array(text.utf8))
    }
  }

  override func doCommand(by selector: Selector) {
    // 日本語入力を通したキーのうち、文字にならなかったもの。
    let bytes: String? =
      switch selector {
      case #selector(insertNewline(_:)): "\r"
      case #selector(insertTab(_:)): "\t"
      case #selector(insertBacktab(_:)): "\u{1b}[Z"
      case #selector(deleteBackward(_:)): "\u{7f}"
      case #selector(cancelOperation(_:)): "\u{1b}"
      default: nil
      }
    if let bytes {
      host.send(Array(bytes.utf8))
    }
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    needsDisplay = true
  }

  func unmarkText() {
    markedText = ""
    needsDisplay = true
  }

  func selectedRange() -> NSRange { NSRange(location: markedText.utf16.count, length: 0) }

  func markedRange() -> NSRange {
    markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count)
  }

  func hasMarkedText() -> Bool { !markedText.isEmpty }

  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let window else { return .zero }
    let fonts = host.fonts(.window)
    let rect = cursorRect ?? CGRect(x: gridOrigin.x, y: gridOrigin.y, width: fonts.cellWidth, height: fonts.cellHeight)
    return window.convertToScreen(convert(rect, to: nil))
  }

  func characterIndex(for point: NSPoint) -> Int { 0 }
}

/// 端末なので、macOS の入力の手助け（確認コードの自動入力・予測入力・自動修正・作文ツールなど）を出さない。
extension GridView: NSTextInputTraits {
  var autocorrectionType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var spellCheckingType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var grammarCheckingType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var smartQuotesType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var smartDashesType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var smartInsertDeleteType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var textReplacementType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var dataDetectionType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var linkDetectionType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var textCompletionType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var inlinePredictionType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var mathExpressionCompletionType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var writingToolsBehavior: NSWritingToolsBehavior {
    get { .none }
    set {}
  }
}

extension Rgb {
  func cgColor(_ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(alpha))
  }

  func nsColor(_ alpha: Double = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(alpha))
  }
}
