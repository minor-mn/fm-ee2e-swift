import Foundation

nonisolated func formatBytes(_ bytes: Int) -> String {
  let units = ["B", "KB", "MB", "GB", "TB"]
  var value = Double(bytes)
  var unit = 0
  while value >= 1024 && unit < units.count - 1 {
    value /= 1024
    unit += 1
  }
  return unit == 0 ? "\(bytes) B" : "\(String(format: value < 10 ? "%.1f" : "%.0f", value)) \(units[unit])"
}

private nonisolated func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

/// 一覧の日時（「26-10-28 06:50」）。
nonisolated func formatDate(_ t: Date) -> String {
  let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: t)
  return "\(two(c.year! % 100))-\(two(c.month!))-\(two(c.day!)) \(two(c.hour!)):\(two(c.minute!))"
}

/// 開いているドライブの容量。取得できない値は nil。
nonisolated struct DiskUsage: Sendable {
  init(total: Int? = nil, used: Int? = nil, free: Int? = nil) {
    self.total = total
    self.used = used
    self.free = free
  }

  let total: Int?
  let used: Int?
  let free: Int?
}

/// `df -Pk` の出力を読む。読めなければ nil。
nonisolated func parseDf(_ output: String) -> DiskUsage? {
  let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
  if lines.count < 2 {
    return nil
  }
  // Filesystem 1024-blocks Used Available Capacity Mounted-on
  let fields = lines.last!.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
  if fields.count < 4 {
    return nil
  }
  func kib(_ s: String) -> Int? { Int(s).map { $0 * 1024 } }
  return DiskUsage(total: kib(fields[1]), used: kib(fields[2]), free: kib(fields[3]))
}

/// [paths] の手元のデータだけを外す（Google ドライブ for デスクトップなどの File Provider の項目。リモートには残り、
/// 開けばまたダウンロードされる）。Finder の「オフラインで使用可能」を外すのと同じ。外せなかったパスを返す。
func evictLocalCopies(_ paths: [String]) async -> [String] {
  if paths.isEmpty {
    return []
  }
  var failed: [String] = []
  for path in paths {
    do {
      try FileManager.default.evictUbiquitousItem(at: URL(fileURLWithPath: path))
    } catch {
      failed.append(path)
    }
  }
  return failed
}
