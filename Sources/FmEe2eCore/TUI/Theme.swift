/// 透明度つきの色（背景に使う）。[alpha] は 0〜1。
nonisolated struct Rgba: Hashable, Sendable {
  init(_ rgb: Rgb, _ alpha: Double = 1) {
    self.rgb = rgb
    self.alpha = alpha
  }

  let rgb: Rgb
  let alpha: Double
}

/// 配色。[Palette] の色と、タブの色（アクセント・カーソルの行の地）。
nonisolated struct ThemeColors: Sendable {
  var background = Rgb(0x12161D)
  var surface = Rgb(0x181D26)
  var surfaceHigh = Rgb(0x212835)
  var outline = Rgb(0x2C3342)
  var text = Rgb(0xEDEFF2)
  var muted = Rgb(0x98A1B0)
  var lime = Rgb(0xE3F86A)
  var yellowGreen = Rgb(0x8EDB3C)
  var purple = Rgb(0x9B6BFF)
  var purpleDeep = Rgb(0x5B34C9)
  var green = Rgb(0x2EE0A8)
  var greenDeep = Rgb(0x128F6D)
  var error = Rgb(0xFF7A6B)
  var red = Rgb(0xFF4D5E)
  var cyan = Rgb(0x5CD8FF)
  var orange = Rgb(0xFF9F43)
  var greenDark = Rgb(0x0F4A3A)
  var orangeDark = Rgb(0x6B3A12)
  var cyanDark = Rgb(0x124A5E)
  var limeDark = Rgb(0x4A5212)
  var addedLine = Rgb(0x12392D)
  var removedLine = Rgb(0x481C24)
  var selected = Rgb(0x3A2A6E)

  /// タブの枠・見出しの色。nil ならタブごとの元の色。
  var accent: Rgb?

  /// 選んでいる窓のカーソルの行の地。nil ならタブごとの元の色。
  var selection: Rgb?

  /// 透明度つき（#RRGGBBAA）で書いた色の透明度（色の値ごと）。GUI 版で地を塗るときに使う。
  var alphas: [Int: Double] = [:]

  /// 上の帯（タイトルの枠）の中の背景の色。nil なら塗らない（窓全体の背景が見える）。
  var header: Rgb?

  /// ステータスバー（下に出て消える状態の表示）の文字の色。
  var statusbar = Rgb(0x5CD8FF)

  /// 窓の先頭の場所（パス）の色。補足の文字より暗い。
  var location = Rgb(0x6B7382)

  /// ファイル名の色（フォルダー・実行ファイル・隠しファイル・マークした項目・シンボリックリンク）。
  var directory = Rgb(0x9B6BFF)
  var executable = Rgb(0xFF4D5E)
  var hidden = Rgb(0x5CD8FF)
  var marked = Rgb(0xE3F86A)
  var symlink = Rgb(0x2EE0A8)

  /// 差分の、追加した行・消した行の印（+・-）と数の色。
  var diffAdded = Rgb(0x2EE0A8)
  var diffRemoved = Rgb(0xFF4D5E)

  /// git status の、変更の種類（[GitStatusLine.statusKey]）ごとの色。ないものは補足の文字の色。
  var gitStatus: [String: Rgb] = [:]

  /// git status のブロックの見出し（staged・unmerged・not_staged・untracked）ごとの色・太字・下線。
  /// ないものは補足の文字の色の太字。
  var gitSectionColor: [String: Rgb] = [:]
  var gitSectionBold: [String: Bool] = [:]
  var gitSectionUnderline: [String: Bool] = [:]

  /// タブの枠・見出しの色。[accent] がなければ [fallback] の色。
  func accent(or fallback: KeyPath<ThemeColors, Rgb>) -> Rgb { accent ?? self[keyPath: fallback] }
}

/// 背景画像の置き方。
nonisolated enum ImageMode: String, Sendable, CaseIterable {
  /// 縦横比を保って全体を覆う（はみ出す分は切る）。
  case fill

  /// 縦横比を保って全体が入るようにする。
  case fit

  /// 元の大きさで中央に置く。
  case center

  /// 元の大きさで並べる。
  case tile
}

/// 背景画像を置く位置。
nonisolated enum ImageAlign: String, Sendable, CaseIterable {
  case topLeft = "top_left"
  case top
  case topRight = "top_right"
  case left
  case center
  case right
  case bottomLeft = "bottom_left"
  case bottom
  case bottomRight = "bottom_right"

  /// 余った幅・高さのうち、左・上に空ける割合。
  var factors: (x: Double, y: Double) {
    switch self {
    case .topLeft: (0, 0)
    case .top: (0.5, 0)
    case .topRight: (1, 0)
    case .left: (0, 0.5)
    case .center: (0.5, 0.5)
    case .right: (1, 0.5)
    case .bottomLeft: (0, 1)
    case .bottom: (0.5, 1)
    case .bottomRight: (1, 1)
    }
  }
}

/// 背景。色の上にグラデーション、その上に画像を重ねる。
nonisolated struct Background: Sendable {
  var color: Rgba?
  var gradient: Gradient?
  var image: BackgroundImage?

  nonisolated struct Gradient: Sendable {
    var from: Rgba
    var to: Rgba

    /// 色が変わる向き（度）。0 で左から右、90 で上から下。
    var angle: Double
  }

  nonisolated struct BackgroundImage: Sendable {
    var path: String
    var mode: ImageMode
    var opacity: Double

    /// 置く位置（tile では使わない）。
    var align = ImageAlign.center

    /// 画像の大きさの上限。塗る範囲の幅・高さに対する割合（0〜1）。fit と center で使う。
    var maxWidth = 1.0
    var maxHeight = 1.0
  }
}

/// 文字。[family] が nil なら等幅のシステムフォント（SF Mono）。
nonisolated struct FontSpec: Sendable, Equatable {
  var family: String?
  var size: Double
}

/// 窓全体（[ThemeKey.window]）または1つのタブの見た目。
nonisolated struct Theme: Sendable {
  var colors = ThemeColors()

  /// この範囲に塗る背景。タブで nil なら塗らずに、下の窓全体の背景を見せる。
  var background: Background?
  var font = FontSpec(family: nil, size: 13)

  /// 上の帯に Used（開いているフォルダーの中身の大きさ）を出す。Google Drive・iCloud Drive のタブだけで使う。
  var showUsed = true

  /// 今描いている範囲の見た目。[Palette] の色はこれを読む。
  nonisolated(unsafe) static var active = Theme(background: Background(color: Rgba(ThemeColors().background)))
}

/// 見た目を分ける単位。窓全体と、タブ（[defaults] は書いていないタブに使う）。
nonisolated enum ThemeKey: String, Sendable, CaseIterable {
  case window
  case defaults = "default"
  case local
  case ssh
  case git
  case icloud
  case drive = "google_drive"
}

/// 設定ファイルの appearance。
nonisolated struct Appearance: Sendable {
  var window: Theme

  /// 窓の背景の不透明度（0〜1）。文字には効かない。
  var opacity = 1.0

  /// 窓の後ろをぼかす。
  var blur = false

  /// タブごとの見た目（default を引き継いだもの）。
  var tabs: [ThemeKey: Theme] = [:]

  /// 見つからなかったフォント（候補をつないだもの）。起動時・読み直したときにステータスバーに出す。
  var missingFonts: [String] = []

  func theme(_ key: ThemeKey) -> Theme {
    key == .window ? window : tabs[key] ?? tabs[.defaults] ?? window
  }

  static let standard = Appearance(window: Theme.active)

  /// 使っている見た目（起動時に設定ファイルから決める）。
  nonisolated(unsafe) static var current = standard
}
