/// 端末上の表示幅。全角（東アジアの広い文字・絵文字）は2、結合文字は0。
nonisolated func runeWidth(_ rune: UInt32) -> Int {
  if rune == 0 || rune < 0x20 || (rune >= 0x7f && rune < 0xa0) {
    return 0
  }
  if isCombining(rune) {
    return 0
  }
  if isWide(rune) {
    return 2
  }
  return 1
}

private nonisolated func isCombining(_ r: UInt32) -> Bool {
  (r >= 0x0300 && r <= 0x036f) || (r >= 0x1ab0 && r <= 0x1aff) || (r >= 0x1dc0 && r <= 0x1dff)
    || (r >= 0x200b && r <= 0x200f) || (r >= 0x20d0 && r <= 0x20ff) || (r >= 0x3099 && r <= 0x309a)
    || (r >= 0xfe00 && r <= 0xfe0f) || (r >= 0xfe20 && r <= 0xfe2f) || (r >= 0xe0100 && r <= 0xe01ef)
}

private nonisolated func isWide(_ r: UInt32) -> Bool {
  (r >= 0x1100 && r <= 0x115f) || (r >= 0x2e80 && r <= 0x303e) || (r >= 0x3041 && r <= 0x33ff)
    || (r >= 0x3400 && r <= 0x4dbf) || (r >= 0x4e00 && r <= 0x9fff) || (r >= 0xa000 && r <= 0xa4cf)
    || (r >= 0xac00 && r <= 0xd7a3) || (r >= 0xf900 && r <= 0xfaff) || (r >= 0xfe30 && r <= 0xfe4f)
    || (r >= 0xff00 && r <= 0xff60) || (r >= 0xffe0 && r <= 0xffe6) || (r >= 0x1f300 && r <= 0x1f64f)
    || (r >= 0x1f900 && r <= 0x1f9ff) || (r >= 0x20000 && r <= 0x3fffd)
}

/// macOSのファイル名はNFD（「が」=「か」+結合濁点）なので、かなの濁点・半濁点だけ合成して表示する。
/// それ以外の結合文字は直前の文字に付けたまま表示する（幅0）。
nonisolated func composeKana(_ s: String) -> String {
  if !s.unicodeScalars.contains(where: { $0.value == 0x3099 || $0.value == 0x309a }) {
    return s
  }
  var out: [UInt32] = []
  for scalar in s.unicodeScalars {
    let r = scalar.value
    if let last = out.last, r == 0x3099 || r == 0x309a, let composed = composeKanaPair(last, handakuten: r == 0x309a) {
      out[out.count - 1] = composed
      continue
    }
    out.append(r)
  }
  var result = String.UnicodeScalarView()
  for r in out {
    if let scalar = Unicode.Scalar(r) {
      result.append(scalar)
    }
  }
  return String(result)
}

private nonisolated let voicedKana: Set<UInt32> = [
  // か〜ぢ（2つおき）
  0x304b, 0x304d, 0x304f, 0x3051, 0x3053, 0x3055, 0x3057, 0x3059, 0x305b, 0x305d, 0x305f, 0x3061,
  0x3064, 0x3066, 0x3068,  // つ て と
  0x306f, 0x3072, 0x3075, 0x3078, 0x307b,  // は行
  0x3046, 0x309d,  // う ゝ
]

private nonisolated func composeKanaPair(_ base: UInt32, handakuten: Bool) -> UInt32? {
  if handakuten {
    // は行: は(306f) ひ ふ へ ほ は3つおき。カタカナは+0x60。
    for start: UInt32 in [0x306f, 0x30cf] {
      if base >= start {
        let offset = base - start
        if offset <= 12 && offset % 3 == 0 {
          return base + 2
        }
      }
    }
    return nil
  }
  if voicedKana.contains(base) {
    return base == 0x3046 ? 0x3094 : base + 1
  }
  if base >= 0x60 && voicedKana.contains(base - 0x60) {
    return base == 0x30a6 ? 0x30f4 : base + 1
  }
  // ワ ヰ ヱ ヲ → ヷ ヸ ヹ ヺ
  if base >= 0x30ef && base <= 0x30f2 {
    return base + 8
  }
  return nil
}

/// 文字列を表示の単位（文字＋結合文字）に分ける。
nonisolated func cells(_ s: String) -> [String] {
  var out: [String] = []
  for scalar in composeKana(s).unicodeScalars {
    let r = scalar.value
    if runeWidth(r) > 0 {
      out.append(String(scalar))
    } else if isCombining(r) && !out.isEmpty {
      out[out.count - 1].unicodeScalars.append(scalar)
    }
  }
  return out
}

nonisolated func cellWidth(_ cell: String) -> Int {
  guard let first = cell.unicodeScalars.first else {
    return 0
  }
  return runeWidth(first.value)
}

nonisolated func textWidth(_ s: String) -> Int {
  cells(s).reduce(0) { $0 + cellWidth($1) }
}

/// 表示幅 [width] に収める。はみ出す場合は末尾を「…」にする。
nonisolated func truncate(_ s: String, _ width: Int) -> String {
  if width <= 0 {
    return ""
  }
  if textWidth(s) <= width {
    return s
  }
  var buffer = ""
  var used = 0
  for cell in cells(s) {
    let w = cellWidth(cell)
    if used + w > width - 1 {
      break
    }
    buffer += cell
    used += w
  }
  return buffer + "…"
}

/// 先頭を「…」にして末尾を残す（パスの表示用）。
nonisolated func truncateLeft(_ s: String, _ width: Int) -> String {
  if width <= 0 {
    return ""
  }
  if textWidth(s) <= width {
    return s
  }
  var kept: [String] = []
  var used = 0
  for cell in cells(s).reversed() {
    let w = cellWidth(cell)
    if used + w > width - 1 {
      break
    }
    kept.append(cell)
    used += w
  }
  return "…" + kept.reversed().joined()
}

nonisolated func padRight(_ s: String, _ width: Int) -> String {
  s + String(repeating: " ", count: min(max(width - textWidth(s), 0), max(width, 0)))
}

nonisolated func padLeft(_ s: String, _ width: Int) -> String {
  String(repeating: " ", count: min(max(width - textWidth(s), 0), max(width, 0))) + s
}
