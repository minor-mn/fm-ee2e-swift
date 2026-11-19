import Darwin
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
  init(total: Int? = nil, used: Int? = nil, free: Int? = nil, memory: MemoryUsage? = nil) {
    self.total = total
    self.used = used
    self.free = free
    self.memory = memory
  }

  let total: Int?
  let used: Int?
  let free: Int?

  /// 接続先（SSH・コンテナ）のメモリ。Linux でなければ（/proc/meminfo がなければ）nil。
  let memory: MemoryUsage?
}

/// メモリの使用量と搭載量（バイト）。
nonisolated struct MemoryUsage: Sendable {
  let used: Int
  let total: Int
}

/// Linux の /proc/meminfo を読む。使用量は MemTotal − MemAvailable。読めなければ nil。
nonisolated func parseMeminfo(_ output: String) -> MemoryUsage? {
  var values: [String: Int] = [:]
  for line in output.components(separatedBy: "\n") {
    let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ":" })
    if fields.count >= 2, let kib = Int(fields[1]) {
      values[String(fields[0])] = kib * 1024
    }
  }
  guard let total = values["MemTotal"], let available = values["MemAvailable"], total > 0 else { return nil }
  return MemoryUsage(used: total - available, total: total)
}

/// [dir] の下のファイルの、元の大きさ（ls の大きさ）の合計。手元から外したクラウドのファイルも数える。数えられなければ nil。
func apparentSize(_ dir: String) async -> Int? {
  // 読めないフォルダーがあると終了コードは 0 でなくなるが、読めた分の合計は出る。
  guard let run = try? await runProcess("/usr/bin/du", ["-A", "-sk", dir]),
    let field = run.stdout.split(whereSeparator: { $0 == " " || $0 == "\t" }).first, let kib = Int(field)
  else {
    return nil
  }
  return kib * 1024
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
/// 1つずつ File Provider に問い合わせるので、メインスレッドを止めないよう別のスレッドで動かす。
nonisolated func evictLocalCopies(_ paths: [String]) async -> [String] {
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

/// Mac のメモリの使用量と搭載量（バイト）。使用量はアクティビティモニタの「使用済みメモリ」と同じ
/// （アプリケーションメモリ＋確保されているメモリ＋圧縮）。読めなければ nil。
nonisolated func memoryUsage() -> MemoryUsage? {
  var stats = vm_statistics64()
  var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
  let result = withUnsafeMutablePointer(to: &stats) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
  }
  guard result == KERN_SUCCESS else { return nil }
  let page = Int(vm_kernel_page_size)
  let app = Int(stats.internal_page_count) - Int(stats.purgeable_count)
  let used = (app + Int(stats.wire_count) + Int(stats.compressor_page_count)) * page
  return MemoryUsage(used: used, total: Int(ProcessInfo.processInfo.physicalMemory))
}
