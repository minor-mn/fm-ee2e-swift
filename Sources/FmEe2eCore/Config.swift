import Foundation

nonisolated var homeDir: String { ProcessInfo.processInfo.environment["HOME"]! }

/// 先頭の「~」（「~」だけか「~/」で始まるもの）を [home] にする。
nonisolated func expandHome(_ path: String, _ home: String) -> String {
  path == "~" || path.hasPrefix("~/") ? home + path.dropFirst() : path
}

/// 鍵ファイルの既定の場所。
nonisolated func keyFileLocation() -> String { p.join(homeDir, ".config", "fm-ee2e", ".fm-ee2e.key") }
