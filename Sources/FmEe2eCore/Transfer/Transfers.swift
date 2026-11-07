import Foundation

/// 転送する1項目（ファイル、または中身ごと送るフォルダー）の状態。
enum TransferState {
  case waiting
  case running
  case done
  case failed(String)
  case cancelled

  /// 終わった（完了・失敗・中止）。
  var finished: Bool {
    switch self {
    case .waiting, .running: false
    case .done, .failed, .cancelled: true
    }
  }
}

/// 転送する1項目。[run] で送る。止めたときは [run] の Task を取り消すので、[run] は取り消しで止まるように書く。
final class TransferItem {
  init(_ name: String, isDir: Bool = false, size: Int? = nil, group: Int = 0, _ run: @escaping () async throws -> Void) {
    self.name = name
    self.isDir = isDir
    self.size = size
    self.group = group
    self.run = run
  }

  /// 一覧に出す名前（フォルダーの中のものは、送るフォルダーからの相対パス）。
  let name: String
  let isDir: Bool
  let size: Int?

  /// 同じ転送の中での、元の対象（マーク）の番号。対象ごとに全部送れたかを数えるのに使う。
  let group: Int

  let run: () async throws -> Void
  var state = TransferState.waiting

  /// 順番待ちの順（小さいものから送る）。やり直すと、そのとき待っているものの後ろになる。
  fileprivate var order = 0

  /// やり直せる（失敗したか、止めた）。
  var retryable: Bool {
    switch state {
    case .failed, .cancelled: true
    default: false
    }
  }
}

/// 1回の転送（G・F12 を1回押した分）。
final class TransferJob {
  /// [finish] は、全部の項目が終わったときに呼ぶ（窓の読み直し・送れた対象のマークを外すなど）。
  init(_ title: String, _ items: [TransferItem], finish: @escaping (TransferJob) async -> Void = { _ in }) {
    self.title = title
    self.items = items
    self.finish = finish
  }

  /// 一覧の見出し（向きと送り先）。
  let title: String
  let items: [TransferItem]
  let finish: (TransferJob) async -> Void

  var finished: Bool { items.allSatisfy { $0.state.finished } }
  var doneCount: Int { items.filter { if case .done = $0.state { true } else { false } }.count }
  var failedCount: Int { items.filter { if case .failed = $0.state { true } else { false } }.count }

  /// [group] の対象の項目が、全部送れたか。
  func groupDone(_ group: Int) -> Bool {
    items.filter { $0.group == group }.allSatisfy { if case .done = $0.state { true } else { false } }
  }
}

/// 裏で動かす転送の順番待ちと履歴。項目を1つずつ順に送る。履歴はアプリを終了するまで残る（保存はしない）。
final class Transfers {
  init() {}

  /// 古い順。
  private(set) var jobs: [TransferJob] = []

  /// 送っている項目と、その Task。
  private var current: (item: TransferItem, task: Task<Void, Error>)?

  /// 状態が変わったとき（描き直す）。
  var onChange: (() -> Void)?

  /// 転送が1つ終わったとき（[TransferJob.finish] のあと）。
  var onJobFinished: ((TransferJob) -> Void)?

  /// 送っている途中か、待っているものがある。
  var busy: Bool { current != nil || jobs.contains { !$0.finished } }

  /// 送っている項目と、その転送。
  var running: (job: TransferJob, item: TransferItem)? {
    guard let item = current?.item, let job = jobs.first(where: { $0.items.contains { $0 === item } }) else { return nil }
    return (job, item)
  }

  /// 次に順番待ちに入れる項目の順。
  private var nextOrder = 0

  private func enqueue(_ item: TransferItem) {
    item.state = .waiting
    item.order = nextOrder
    nextOrder += 1
  }

  /// [job] を順番待ちに足す。空いていれば送り始める。
  func add(_ job: TransferJob) {
    job.items.forEach(enqueue)
    jobs.append(job)
    onChange?()
    if job.items.isEmpty {
      Task { await finish(job) }
    }
    pump()
  }

  /// [item] を止める。待っていれば外し、送っていれば取り消す。
  func cancel(_ item: TransferItem) {
    switch item.state {
    case .waiting:
      item.state = .cancelled
      if let job = jobs.first(where: { $0.items.contains { $0 === item } }), job.finished {
        Task { await finish(job) }
      }
    case .running:
      current?.task.cancel()
    default:
      return
    }
    onChange?()
  }

  /// [job] の、まだ終わっていない項目を全部止める。
  func cancel(_ job: TransferJob) {
    // 待っているものを先に外してから送っているものを止める（止めた直後に次を送り始めないように）。
    for item in job.items {
      if case .waiting = item.state {
        item.state = .cancelled
      }
    }
    if let item = job.items.first(where: { if case .running = $0.state { true } else { false } }) {
      cancel(item)
    } else if job.finished {
      Task { await finish(job) }
    }
    onChange?()
  }

  /// 失敗した・止めた [items] をやり直す。今待っているものの後ろに入れ、終わったら転送の後始末（[TransferJob.finish]）ももう一度行う。
  func retry(_ items: [TransferItem]) {
    let targets = items.filter(\.retryable)
    if targets.isEmpty {
      return
    }
    for item in targets {
      enqueue(item)
      if let job = jobs.first(where: { $0.items.contains { $0 === item } }) {
        finishedJobs.remove(ObjectIdentifier(job))
      }
    }
    onChange?()
    pump()
  }

  /// 次の待っている項目（順番待ちの順の最も小さいもの）を送る。送っている間は何もしない。
  private func pump() {
    if current != nil {
      return
    }
    let waiting = jobs.flatMap { job in
      job.items.filter { if case .waiting = $0.state { true } else { false } }.map { (job, $0) }
    }
    guard let (job, item) = waiting.min(by: { $0.1.order < $1.1.order }) else {
      return
    }
    item.state = .running
    let task = Task { try await item.run() }
    current = (item, task)
    onChange?()
    Task {
      do {
        try await task.value
        item.state = .done
      } catch {
        item.state = task.isCancelled ? .cancelled : .failed(errorMessage(error))
      }
      current = nil
      if job.finished {
        await finish(job)
      }
      onChange?()
      pump()
    }
  }

  /// [job] の後始末（1回だけ）。
  private var finishedJobs: Set<ObjectIdentifier> = []

  private func finish(_ job: TransferJob) async {
    if !finishedJobs.insert(ObjectIdentifier(job)).inserted {
      return
    }
    await job.finish(job)
    onJobFinished?(job)
    onChange?()
  }
}

/// 取り消された Task の中からでも、取り消されずに最後まで動かす（止めた転送の後片付けなど）。
func uncancelled<T>(_ body: @escaping () async throws -> T) async throws -> T {
  try await Task { try await body() }.value
}
