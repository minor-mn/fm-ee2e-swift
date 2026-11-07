import Foundation

/// 転送タブ。G・F12 の転送の履歴（[Transfers]）を、転送ごとの見出しの行と、その下の項目の行で出す。
/// 最初の転送を始めたときに作られ、転送先の側に出る。G・F12 のメニューで、カーソル（マークがあればマーク）の転送・項目を
/// 止め（cancel）、失敗した・止めた項目をやり直す（retry）。Enter で、切り替わる前のタブに戻る。
final class TransfersPane: Pane {
  init(_ app: App, _ transfers: Transfers) {
    self.transfers = transfers
    super.init(app)
    refresh()
  }

  let transfers: Transfers

  override var title: String { tr("transfers.title") }

  override var location: String { "" }

  override var accent: Rgb { colors.accent ?? colors.lime }

  /// 上の帯には、容量の代わりに件数を出す。
  override var headerText: String? {
    let items = transfers.jobs.flatMap(\.items)
    func count(_ test: (TransferState) -> Bool) -> Int { items.filter { test($0.state) }.count }
    return tr(
      "transfers.summary",
      [
        "running": count { if case .running = $0 { true } else { false } },
        "waiting": count { if case .waiting = $0 { true } else { false } },
        "done": count { if case .done = $0 { true } else { false } },
        "failed": count { if case .failed = $0 { true } else { false } },
        "cancelled": count { if case .cancelled = $0 { true } else { false } },
      ]
    )
  }

  override var usageLabels: [String] { [] }

  override var canGoUp: Bool { false }

  override var folderKey: String { "" }

  /// 行は、転送・項目そのもので見分ける（同じ名前の行が並ぶことがある）。
  override func keyOf(_ entry: Entry) -> String { "\(ObjectIdentifier(entry.data as AnyObject).hashValue)" }

  override var commands: [Operation: Command] { [.enter: LeaveTransfers(), .transfer: TransferMenu()] }

  override func fetch() async throws -> [Entry] { rows() }

  /// 履歴の行（古い転送から順に、見出しとその項目）。
  private func rows() -> [Entry] {
    transfers.jobs.flatMap { job in
      [Entry(name: job.title, isDir: false, data: job)]
        + job.items.map { Entry(name: $0.name, isDir: $0.isDir, size: $0.size, data: $0) }
    }
  }

  /// 履歴が変わった（次に描くときに並べ直す）。小さいファイルが続くと状態が次々に変わるので、変わるたびには並べ直さない。
  var needsRefresh = false

  override func draw(_ screen: Screen, _ x: Int, _ y: Int, _ w: Int, _ h: Int, focused: Bool, accentBorder: Bool) {
    if needsRefresh {
      refresh()
    }
    super.draw(screen, x, y, w, h, focused: focused, accentBorder: accentBorder)
  }

  /// 履歴が変わったら、カーソルの行を保ったまま並べ直す。
  func refresh() {
    needsRefresh = false
    let key = current.map(keyOf)
    entries = rows()
    if let key, let index = entries.firstIndex(where: { keyOf($0) == key }) {
      cursor = index
    } else {
      cursor = min(max(cursor, 0), max(entries.count - 1, 0))
    }
  }

  override func drawRow(_ screen: Screen, _ entry: Entry, _ x: Int, _ y: Int, _ width: Int, _ style: Style, marked: Bool) {
    screen.text(x, y, marked ? "*" : " ", style.copyWith(fg: Palette.marked, bold: true))
    if let job = entry.data as? TransferJob {
      let count = " \(job.doneCount)/\(job.items.count)"
      let failed = job.failedCount > 0 ? " " + tr("transfers.failed_count", ["count": job.failedCount]) : ""
      let tail = count + failed
      let titleWidth = max(0, width - 2 - textWidth(tail))
      let col = x + 2 + screen.text(x + 2, y, truncate(job.title, titleWidth), style.copyWith(fg: accent, bold: true))
      screen.text(col, y, count, style.copyWith(fg: Palette.muted))
      if !failed.isEmpty {
        screen.text(col + textWidth(count), y, failed, style.copyWith(fg: Palette.error))
      }
      return
    }
    guard let item = entry.data as? TransferItem else { return }
    let (mark, color): (String, Rgb) =
      switch item.state {
      case .waiting: ("・", Palette.muted)
      case .running: ("▶", Palette.lime)
      case .done: ("✓", Palette.green)
      case .failed: ("✗", Palette.error)
      case .cancelled: ("－", Palette.muted)
      }
    let name = item.isDir ? "\(item.name)/" : item.name
    let nameColor = marked ? Palette.marked : item.isDir ? Palette.directory : fileColor
    var col = x + 4
    screen.text(x + 2, y, mark, style.copyWith(fg: color, bold: true))
    if case .failed(let reason) = item.state {
      // 失敗した理由は、名前のあとに続ける。
      let nameWidth = min(textWidth(name), max(0, (width - 4) / 2))
      col += screen.text(col, y, truncate(name, nameWidth), style.copyWith(fg: nameColor, bold: marked))
      screen.text(col + 1, y, truncate(reason.replacingOccurrences(of: "\n", with: " "), max(0, x + width - col - 1)), style.copyWith(fg: Palette.error))
      return
    }
    let nameWidth = max(0, width - 4 - 10)
    screen.text(col, y, truncate(name, nameWidth), style.copyWith(fg: nameColor, bold: marked))
    col += nameWidth + 1
    let size = item.isDir ? "<DIR>" : (item.size.map(formatBytes) ?? "")
    screen.text(col, y, padLeft(size, 9), style.copyWith(fg: Palette.muted))
  }
}

/// 転送タブで Enter。切り替わる前のタブに戻る（転送は裏で続く）。
final class LeaveTransfers: Command {
  override var needsReady: Bool { false }

  override func run(_ c: CommandContext) async { c.workspace.leaveTransfers() }
}

/// 転送タブの G・F12。カーソル（マークがあればマーク）の転送・項目に使える操作を小窓のメニューに出す（Git のタブと同じ）。
/// 待っている・送っている項目があれば cancel（確かめずにすぐ止める）、送っている転送があれば cancel running
/// （カーソルによらず、その転送の残りをまるごと止める）、失敗した・止めた項目があれば retry。
/// 見出しの行は、その転送の項目すべてを対象にする。使える操作がなければ何もしない。
final class TransferMenu: Command {
  override var label: String { "Transfer" }

  override func run(_ c: CommandContext) async {
    guard let pane = c.pane as? TransfersPane else { return }
    let items = c.targets.flatMap { mark -> [TransferItem] in
      if let job = mark.entry.data as? TransferJob {
        return job.items
      }
      return (mark.entry.data as? TransferItem).map { [$0] } ?? []
    }
    let retryable = items.filter(\.retryable)
    let cancellable = items.filter { !$0.state.finished }
    // 送っている転送（G 1回分）は、カーソルの位置によらず、まるごと止められる。
    let running = pane.transfers.running?.job
    var options: [String] = []
    if !cancellable.isEmpty {
      options.append("cancel")
    }
    if running != nil {
      options.append("cancel running")
    }
    if !retryable.isEmpty {
      options.append("retry")
    }
    if options.isEmpty {
      return
    }
    // G・F12 で開いたので、もう一度 G・F12 を押すと閉じる。端で ↑↓ を押しても閉じる。
    guard
      let choice = await c.app.askChoice(
        label, options, closeKey: { key in key.name == "f12" || key.isLetter("g") }, closeAtEdges: true)
    else {
      return
    }
    switch options[choice] {
    case "cancel":
      // 待っているものを先に外してから、送っているものを止める（止めた直後に、外す前の次のものを送り始めないように）。
      let waiting = cancellable.filter { if case .waiting = $0.state { true } else { false } }
      for item in waiting + cancellable.filter({ item in !waiting.contains { $0 === item } }) {
        pane.transfers.cancel(item)
      }
    case "cancel running":
      // メニューを開いている間に終わっていれば、何もしない。
      if let running, !running.finished {
        pane.transfers.cancel(running)
      }
    case "retry":
      pane.transfers.retry(retryable)
    default:
      return
    }
    pane.marks.clear()
    pane.refresh()
  }
}
