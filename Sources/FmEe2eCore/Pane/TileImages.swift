import AppKit

/// タイル表示（Ctrl+T）のサムネイル。見えているタイルの分だけ、[maxLoads] 件ずつ作り、最近の [maxCached] 件を覚えておく。
final class TileImages {
  init(_ app: App) {
    self.app = app
  }

  let app: App

  /// 同時に作る数。SSH は1件ずつ cat し、Google Drive は復号するので、多くしない。
  private static let maxLoads = 4

  private static let maxCached = 300

  /// 作ったサムネイル。作れなかったものは nil。
  private var images = OrderedMap<String, NSImage?>()

  /// 作っているもの。
  private var loading: Set<String> = []

  /// これから作るもの（見えている順）。
  private var queue: [(id: String, make: () async -> NSImage?)] = []

  /// [id] のサムネイル。まだ作っていなければ nil、作れなかったものは .some(nil)。
  func image(_ id: String) -> NSImage?? { images[id] }

  /// これから作るものを、今見えていて、まだないもの（[wanted]）に置き換える（見えなくなったものは作らない）。
  func request(_ wanted: [(id: String, make: () async -> NSImage?)]) {
    queue = wanted.filter { !images.containsKey($0.id) && !loading.contains($0.id) }
    pump()
  }

  private func pump() {
    while loading.count < Self.maxLoads, !queue.isEmpty {
      let (id, make) = queue.removeFirst()
      loading.insert(id)
      Task {
        let image = await make()
        loading.remove(id)
        images.removeValue(forKey: id)
        images[id] = .some(image)
        if images.count > Self.maxCached, let first = images.keys.first {
          images.removeValue(forKey: first)
        }
        app.requestRender()
        pump()
      }
    }
  }
}
