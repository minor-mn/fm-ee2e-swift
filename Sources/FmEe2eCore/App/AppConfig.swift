import AppKit

/// 設定ファイル（~/.config/fm-ee2e/config.json5）。
///
/// ```json
/// {
///   "right_tabs": {
///     "google_drive": true,
///     "git": true,
///     "ssh": true,
///     "icloud": true,
///     "local": true
///   }
/// }
/// ```
///
/// ファイルや項目がなければ true。コメント（// と /* */）と末尾のカンマも書ける（JSON5）。
struct AppConfig {
  init(language: String = "ja", rightTabs: [RightMode] = RightMode.allCases, appearance: Appearance = .standard) {
    self.language = language
    self.rightTabs = rightTabs
    self.appearance = appearance
  }

  /// 画面の言葉（~/.config/fm-ee2e/languages/<language>.json5 を読む。ファイルがあれば、どの名前でもよい）。
  let language: String

  /// 右の窓に出すタブ（Tab で切り替える順）。
  let rightTabs: [RightMode]

  /// 見た目（appearance）。書き方は [parseAppearance]。
  let appearance: Appearance

  static var file: String { p.join(homeDir, ".config", "fm-ee2e", "config.json5") }

  /// 設定ファイルでのタブの名前（書く順）。
  private static let tabNames: [(String, RightMode)] = [
    ("google_drive", .drive),
    ("git", .git),
    ("ssh", .ssh),
    ("icloud", .icloud),
    ("local", .local),
  ]

  /// [file] を読む。なければ既定の設定。形式が違えば [ConfigFormatError]。
  static func load() async throws -> AppConfig {
    guard let data = FileManager.default.contents(atPath: file) else {
      return AppConfig()
    }
    return try parse(data)
  }

  /// 設定ファイルの中身 [data] を読む。空なら既定の設定。
  static func parse(_ data: Data) throws -> AppConfig {
    if String(decoding: data, as: UTF8.self).allSatisfy(\.isWhitespace) {
      return AppConfig()
    }
    let json: Any
    do {
      json = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
    } catch {
      let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
      throw ConfigFormatError(tr("app_config.not_json") + (detail.map { tr("app_config.not_json_detail", ["detail": $0]) } ?? ""))
    }
    guard let root = json as? [String: Any] else {
      throw ConfigFormatError(tr("app_config.root_not_object"))
    }
    let rootKeys = ["language", "right_tabs", "appearance"]
    for key in root.keys where !rootKeys.contains(key) {
      throw ConfigFormatError(tr("app_config.unknown_root_key", ["key": key, "names": list(rootKeys)]))
    }
    var language = "ja"
    if let value = root["language"], !(value is NSNull) {
      // ファイルの名前にするので、ほかのフォルダーを指す「/」や「..」は書けない。
      guard let name = value as? String, name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
        throw ConfigFormatError(tr("app_config.language_invalid"))
      }
      language = name
    }
    let appearance = try parseAppearance(root["appearance"])
    guard let tabs = root["right_tabs"], !(tabs is NSNull) else {
      return AppConfig(language: language, appearance: appearance)
    }
    guard let entries = tabs as? [String: Any] else {
      throw ConfigFormatError(tr("app_config.right_tabs_not_object"))
    }
    var off = Set<RightMode>()
    for (key, value) in entries {
      guard let mode = tabNames.first(where: { $0.0 == key })?.1 else {
        throw unknownKey("right_tabs", key, tabNames.map(\.0))
      }
      guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
        throw ConfigFormatError(tr("app_config.right_tabs_not_bool", ["key": key]))
      }
      if !number.boolValue {
        off.insert(mode)
      }
    }
    return AppConfig(language: language, rightTabs: RightMode.allCases.filter { !off.contains($0) }, appearance: appearance)
  }

  /// appearance を読む。
  ///
  /// - window: 窓全体（opacity・blur と、[elementNames] の要素）。
  /// - default: 書いていないタブに使う（[elementNames] の要素）。
  /// - local・ssh・git・icloud・google_drive: タブごと。書いていない項目は default を、default にもなければ window を引き継ぐ。
  ///   ただし background は window から引き継がない（塗らなければ、下の窓全体の背景が見える）。
  /// 項目に null を書くと、引き継いだ値を消す。
  static func parseAppearance(_ value: Any?) throws -> Appearance {
    guard let value, !(value is NSNull) else {
      return .standard
    }
    let blocks = try dictionary(value, "appearance")
    for key in blocks.keys where ThemeKey(rawValue: key) == nil {
      throw unknownKey("appearance", key, ThemeKey.allCases.map(\.rawValue))
    }
    func block(_ key: ThemeKey) throws -> [String: Any] {
      guard let value = blocks[key.rawValue], !(value is NSNull) else {
        return [:]
      }
      let block = try dictionary(value, "appearance.\(key.rawValue)")
      var allowed = elementTree
      if key == .window {
        allowed["opacity"] = true
        allowed["blur"] = true
      }
      if key == .drive || key == .icloud {
        allowed["show_used"] = true
      }
      try checkKeys(block, allowed, "appearance.\(key.rawValue)")
      return block
    }
    let windowBlock = try block(.window)
    var missingFonts: [String] = []
    var appearance = Appearance(window: try theme(windowBlock, "appearance.window", base: Appearance.standard.window, &missingFonts))
    // 窓全体の画面で塗らずに背景を見せる地の色は、窓全体の背景の色。
    appearance.window.colors.background = appearance.window.background?.color?.rgb ?? ThemeColors().background
    if let opacity = windowBlock["opacity"], !(opacity is NSNull) {
      appearance.opacity = try number(opacity, "appearance.window.opacity", 0...1)
    }
    if let blur = windowBlock["blur"], !(blur is NSNull) {
      appearance.blur = try bool(blur, "appearance.window.blur")
    }
    // タブは、窓全体の色・文字を土台に、default、タブの順に重ねる（背景は窓全体から引き継がない）。
    var base = appearance.window
    base.background = nil
    let defaults = try block(.defaults)
    for key in ThemeKey.allCases where key != .window {
      let merged = key == .defaults ? defaults : merge(defaults, try block(key))
      var tab = try theme(merged, "appearance.\(key.rawValue)", base: base, &missingFonts)
      if let value = merged["show_used"], !(value is NSNull) {
        tab.showUsed = try bool(value, "appearance.\(key.rawValue).show_used")
      }
      // 枠の中の地の色は、タブの背景の色。なければ窓全体の背景の色のまま。
      tab.colors.background = tab.background?.color?.rgb ?? appearance.window.colors.background
      appearance.tabs[key] = tab
    }
    appearance.missingFonts = missingFonts
    return appearance
  }

  /// [over] の項目で [base] を上書きする。対応付けは項目ごとに重ね、null は項目を消す。
  static func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
    var result = base
    for (key, value) in over {
      if value is NSNull {
        result.removeValue(forKey: key)
      } else if let inner = value as? [String: Any], let old = result[key] as? [String: Any] {
        result[key] = merge(old, inner)
      } else {
        result[key] = value
      }
    }
    return result
  }

  /// 要素ごとの色の書き場所（ブロックの中のパス）と、それを入れる [ThemeColors] の色。
  /// 地の色（パスに background を含む）は、#RRGGBBAA で透明度も書ける（GUI 版だけ効く）。
  private static let colorElements: [(path: [String], apply: (inout ThemeColors, Rgb) -> Void)] = [
    (["text", "color"], { $0.text = $1 }),
    (["subtext", "color"], { $0.muted = $1 }),
    (["location", "color"], { $0.location = $1 }),
    (["statusbar", "color"], { $0.statusbar = $1 }),
    (["header", "background", "color"], { $0.header = $1 }),
    (["border", "color"], { $0.outline = $1 }),
    (["highlight", "color"], { $0.lime = $1 }),
    (["error", "color"], { $0.error = $1 }),
    (["accent", "color"], { $0.accent = $1 }),
    (["cursor", "background", "color"], { $0.selection = $1 }),
    (["panel", "background", "color"], { $0.surface = $1 }),
    (["dialog", "background", "color"], { $0.surfaceHigh = $1 }),
    (["files", "directory", "color"], { $0.directory = $1 }),
    (["files", "executable", "color"], { $0.executable = $1 }),
    (["files", "hidden", "color"], { $0.hidden = $1 }),
    (["files", "marked", "color"], { $0.marked = $1 }),
    (["files", "symlink", "color"], { $0.symlink = $1 }),
    (["diff", "added", "color"], { $0.diffAdded = $1 }),
    (["diff", "added", "background", "color"], { $0.addedLine = $1 }),
    (["diff", "removed", "color"], { $0.diffRemoved = $1 }),
    (["diff", "removed", "background", "color"], { $0.removedLine = $1 }),
  ]
    + gitStatusKeys.map { key in (["status", key, "color"], { $0.gitStatus[key] = $1 }) }
    + gitSectionKeys.map { key in (["sections", key, "color"], { $0.gitSectionColor[key] = $1 }) }

  /// git status の、見た目を決められるブロックの見出し。
  static let gitSectionKeys = ["staged", "unmerged", "not_staged", "untracked"]

  /// git status の右の列の、色を決められる変更の種類。conflict は競合（unmerged）のすべて。
  static let gitStatusKeys = ["modified", "new_file", "deleted", "renamed", "copied", "type", "conflict"]

  /// ブロックに書ける項目の木（葉は true）。background と font は中身を別に確かめる。
  private static var elementTree: [String: Any] {
    var tree: [String: Any] = ["background": true, "font": true]
    func add(_ path: ArraySlice<String>, _ node: inout [String: Any]) {
      guard let head = path.first else { return }
      if path.count == 1 {
        node[head] = true
        return
      }
      var child = node[head] as? [String: Any] ?? [:]
      add(path.dropFirst(), &child)
      node[head] = child
    }
    for (path, _) in colorElements {
      add(path[...], &tree)
    }
    for key in gitSectionKeys {
      add(["sections", key, "bold"], &tree)
      add(["sections", key, "underline"], &tree)
    }
    return tree
  }

  /// [block] に、[tree] にない項目がないか確かめる。
  private static func checkKeys(_ block: [String: Any], _ tree: [String: Any], _ path: String) throws {
    for (name, value) in block {
      guard let node = tree[name] else {
        throw unknownKey(path, name, tree.keys.sorted())
      }
      if let children = node as? [String: Any], !(value is NSNull) {
        try checkKeys(try dictionary(value, "\(path).\(name)"), children, "\(path).\(name)")
      }
    }
  }

  /// [block] を [base] に重ねる。
  /// どれも見つからなかったフォントの候補は [missingFonts] に足す（同じものは1度だけ）。
  private static func theme(_ block: [String: Any], _ path: String, base: Theme, _ missingFonts: inout [String]) throws -> Theme {
    var theme = base
    for (elementPath, apply) in colorElements {
      var value: Any? = block
      for name in elementPath {
        value = (value as? [String: Any])?[name]
      }
      guard let value, !(value is NSNull) else {
        continue
      }
      let where_ = ([path] + elementPath).joined(separator: ".")
      let color = try rgba(value, where_)
      if color.alpha < 1 && !elementPath.contains("background") {
        throw ConfigFormatError(tr("app_config.alpha_only_background", ["path": where_]))
      }
      apply(&theme.colors, color.rgb)
      if color.alpha < 1 {
        theme.colors.alphas[color.rgb.value] = color.alpha
      } else {
        theme.colors.alphas.removeValue(forKey: color.rgb.value)
      }
    }
    // git status の見出しの太字・下線（色は colorElements で読む）。
    for key in gitSectionKeys {
      let section = ((block["sections"] as? [String: Any])?[key] as? [String: Any]) ?? [:]
      if let value = section["bold"], !(value is NSNull) {
        theme.colors.gitSectionBold[key] = try bool(value, "\(path).sections.\(key).bold")
      }
      if let value = section["underline"], !(value is NSNull) {
        theme.colors.gitSectionUnderline[key] = try bool(value, "\(path).sections.\(key).underline")
      }
    }
    if let value = block["font"], !(value is NSNull) {
      let font = try dictionary(value, "\(path).font")
      for name in font.keys where !["family", "size"].contains(name) {
        throw unknownKey("\(path).font", name, ["family", "size"])
      }
      // 候補を上から探し、入っている最初のフォントを使う。どれもなければ SF Mono。
      if let family = font["family"], !(family is NSNull) {
        let names: [String]
        if let name = family as? String {
          names = [name]
        } else if let list = family as? [Any], !list.isEmpty, list.allSatisfy({ $0 is String }) {
          names = list as! [String]
        } else {
          throw ConfigFormatError(tr("app_config.font_family_invalid", ["path": path]))
        }
        theme.font.family = names.first { NSFont(name: $0, size: 12) != nil }
        let joined = list(names)
        if theme.font.family == nil && !missingFonts.contains(joined) {
          missingFonts.append(joined)
        }
      }
      if let size = font["size"], !(size is NSNull) {
        theme.font.size = try number(size, "\(path).font.size", 6...72)
      }
    }
    if let value = block["background"], !(value is NSNull) {
      theme.background = try background(try dictionary(value, "\(path).background"), "\(path).background", base: base.background)
    } else if block.keys.contains("background") {
      theme.background = nil
    }
    return theme
  }

  private static func background(_ block: [String: Any], _ path: String, base: Background?) throws -> Background {
    for name in block.keys where !["color", "gradient", "image"].contains(name) {
      throw unknownKey(path, name, ["color", "gradient", "image"])
    }
    var result = base ?? Background()
    if let value = block["color"] {
      result.color = value is NSNull ? nil : try rgba(value, "\(path).color")
    }
    if let value = block["gradient"] {
      if value is NSNull {
        result.gradient = nil
      } else {
        let gradient = try dictionary(value, "\(path).gradient")
        for name in gradient.keys where !["from", "to", "angle"].contains(name) {
          throw unknownKey("\(path).gradient", name, ["from", "to", "angle"])
        }
        guard let from = gradient["from"], let to = gradient["to"] else {
          throw ConfigFormatError(tr("app_config.gradient_needs_from_to", ["path": path]))
        }
        result.gradient = Background.Gradient(
          from: try rgba(from, "\(path).gradient.from"),
          to: try rgba(to, "\(path).gradient.to"),
          angle: try gradient["angle"].map { try number($0, "\(path).gradient.angle", -360...360) } ?? 90
        )
      }
    }
    if let value = block["image"] {
      if value is NSNull {
        result.image = nil
      } else {
        let image = try dictionary(value, "\(path).image")
        let names = ["path", "mode", "opacity", "align", "max_width", "max_height"]
        for name in image.keys where !names.contains(name) {
          throw unknownKey("\(path).image", name, names)
        }
        guard let file = image["path"] as? String, !file.isEmpty else {
          throw ConfigFormatError(tr("app_config.image_path_missing", ["path": path]))
        }
        var mode = ImageMode.fill
        if let value = image["mode"] {
          guard let name = value as? String, let found = ImageMode(rawValue: name) else {
            throw ConfigFormatError(
              tr("app_config.one_of", ["path": "\(path).image.mode", "names": list(ImageMode.allCases.map(\.rawValue))])
            )
          }
          mode = found
        }
        var align = ImageAlign.center
        if let value = image["align"] {
          guard let name = value as? String, let found = ImageAlign(rawValue: name) else {
            throw ConfigFormatError(
              tr("app_config.one_of", ["path": "\(path).image.align", "names": list(ImageAlign.allCases.map(\.rawValue))])
            )
          }
          align = found
        }
        result.image = Background.BackgroundImage(
          path: (file as NSString).expandingTildeInPath,
          mode: mode,
          opacity: try image["opacity"].map { try number($0, "\(path).image.opacity", 0...1) } ?? 1,
          align: align,
          maxWidth: try image["max_width"].map { try number($0, "\(path).image.max_width", 0.01...1) } ?? 1,
          maxHeight: try image["max_height"].map { try number($0, "\(path).image.max_height", 0.01...1) } ?? 1
        )
      }
    }
    return result
  }

  private static func dictionary(_ value: Any, _ path: String) throws -> [String: Any] {
    guard let result = value as? [String: Any] else {
      throw ConfigFormatError(tr("app_config.not_object", ["path": path]))
    }
    return result
  }

  private static func isBool(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  private static func bool(_ value: Any, _ path: String) throws -> Bool {
    guard isBool(value) else {
      throw ConfigFormatError(tr("app_config.not_bool", ["path": path]))
    }
    return (value as! NSNumber).boolValue
  }

  private static func number(_ value: Any, _ path: String, _ range: ClosedRange<Double>) throws -> Double {
    guard let number = value as? NSNumber, !isBool(value), range.contains(number.doubleValue) else {
      throw ConfigFormatError(
        tr("app_config.out_of_range", ["path": path, "min": formatNumber(range.lowerBound), "max": formatNumber(range.upperBound)])
      )
    }
    return number.doubleValue
  }

  /// 名前を並べた文言（「・」などでつなぐ）。
  private static func list(_ names: [String]) -> String {
    names.joined(separator: tr("app_config.list_separator"))
  }

  /// [path] の [name] は使えない、という誤り（使える名前 [names] を添える）。
  private static func unknownKey(_ path: String, _ name: String, _ names: [String]) -> ConfigFormatError {
    ConfigFormatError(tr("app_config.unknown_key", ["path": path, "name": name, "names": list(names)]))
  }

  private static func formatNumber(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(value)
  }

  /// 「#RRGGBB」か、透明度つきの「#RRGGBBAA」。
  private static func rgba(_ value: Any, _ path: String) throws -> Rgba {
    guard let text = value as? String, text.hasPrefix("#"), [7, 9].contains(text.count),
      let number = Int(text.dropFirst(), radix: 16)
    else {
      throw ConfigFormatError(tr("app_config.not_color", ["path": path]))
    }
    return text.count == 7 ? Rgba(Rgb(number)) : Rgba(Rgb(number >> 8), Double(number & 0xff) / 255)
  }
}

/// 設定ファイルの形式の誤り（Dart の FormatException）。
struct ConfigFormatError: Error, CustomStringConvertible {
  init(_ message: String) {
    self.message = message
  }

  let message: String

  var description: String { message }
}
