import Foundation

/// 変更の通知（FlutterのChangeNotifierの代わり）。
class Notifier {
  private var listeners: [(id: Int, listener: () -> Void)] = []
  private var nextId = 0

  /// 外すときに [removeListener] に渡す番号を返す。
  @discardableResult
  func addListener(_ listener: @escaping () -> Void) -> Int {
    nextId += 1
    listeners.append((nextId, listener))
    return nextId
  }

  func removeListener(_ id: Int) {
    listeners.removeAll { $0.id == id }
  }

  func notifyListeners() {
    for (_, listener) in listeners {
      listener()
    }
  }
}

/// 値の通知（Dart の broadcast な Stream の代わり）。
final class Broadcast<T> {
  private var listeners: [(id: Int, listener: (T) -> Void)] = []
  private var nextId = 0

  /// 外すときに [cancel] に渡す番号を返す。
  @discardableResult
  func listen(_ listener: @escaping (T) -> Void) -> Int {
    nextId += 1
    listeners.append((nextId, listener))
    return nextId
  }

  func cancel(_ id: Int) {
    listeners.removeAll { $0.id == id }
  }

  func add(_ value: T) {
    for (_, listener) in listeners {
      listener(value)
    }
  }

  /// [test] に当たる最初の値を待つ。
  func first(where test: @escaping (T) -> Bool) async -> T {
    await withCheckedContinuation { continuation in
      var id = 0
      id = listen { [weak self] value in
        if test(value) {
          self?.cancel(id)
          continuation.resume(returning: value)
        }
      }
    }
  }
}

/// 一定時間後に1回だけ呼ぶ（Dart の Timer の代わり）。メインスレッドで呼ぶ。
final class OneShotTimer {
  private var item: DispatchWorkItem?

  init(milliseconds: Int, _ action: @escaping () -> Void) {
    let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
    self.item = item
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: item)
  }

  var isActive: Bool { item.map { !$0.isCancelled } ?? false }

  func cancel() {
    item?.cancel()
    item = nil
  }
}

/// 一定間隔で呼ぶ（Dart の Timer.periodic の代わり）。メインスレッドで呼ぶ。
final class PeriodicTimer {
  private let source: DispatchSourceTimer

  init(milliseconds: Int, _ action: @escaping () -> Void) {
    source = DispatchSource.makeTimerSource(queue: .main)
    source.schedule(deadline: .now() + .milliseconds(milliseconds), repeating: .milliseconds(milliseconds))
    source.setEventHandler { MainActor.assumeIsolated { action() } }
    source.resume()
  }

  func cancel() {
    source.cancel()
  }
}

/// [milliseconds] だけ待つ（Future.delayed の代わり）。
func delay(milliseconds: Int) async {
  try? await Task.sleep(for: .milliseconds(milliseconds))
}
