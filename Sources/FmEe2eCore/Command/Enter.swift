/// Enter。項目の種類によって動きが違うので、マークにかかわらず、いつもカーソルの項目に対して行う。
/// 親フォルダー（..）なら上へ、ほかはタブの開き方（[Pane.open]）で開く。
class EnterCommand: Command {
  override var needsReady: Bool { false }

  override var includesParent: Bool { true }

  override var cursorOnly: Bool { true }

  override func run(_ c: CommandContext) async {
    let pane = c.pane
    guard let target = c.targets.first, !pane.loading else {
      return
    }
    if target.entry.isParent {
      await pane.up()
    } else {
      await pane.open(target.entry)
    }
  }
}
