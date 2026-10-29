import Foundation

/// Google Drive のタブが使えないときの Enter。鍵ファイルがなければ用意する（新しく生成・既存の鍵をペースト）。
/// 読めない鍵ファイルは上書きしない（直して L で確かめ直す）。
final class DriveSetup: Command {
  override var needsReady: Bool { false }

  override func run(_ c: CommandContext) async {
    let pane = c.pane as! DrivePane
    if pane.state == .noKey {
      await setUpKey(c, pane)
    }
  }

  private func setUpKey(_ c: CommandContext, _ pane: DrivePane) async {
    let choice = await c.app.askChoice("鍵を用意する", ["新しい鍵を生成", "既存の鍵をペースト"])
    let key: Data? =
      switch choice {
      case 0: await generate(c, pane)
      case 1: await paste(c)
      default: nil
      }
    guard let key else {
      return
    }
    do {
      try await KeyFile.save(pane.keyFile, key)
    } catch {
      await c.app.showError("保存できませんでした: \(errorMessage(error))")
      return
    }
    await pane.check()
  }

  private func generate(_ c: CommandContext, _ pane: DrivePane) async -> Data? {
    let ok = await c.app.confirm(
      "新しい鍵を生成",
      "新しい鍵を \(pane.keyFile) に保存します。\n鍵を失うと暗号化したファイルは復号できません。バックアップを別に保管してください。",
      yes: "生成する"
    )
    return ok ? KeyFile.generate() : nil
  }

  private func paste(_ c: CommandContext) async -> Data? {
    let text = await c.app.input(
      "既存の鍵をペースト",
      message: "1行目が \(KeyFile.header)、2行目が鍵のBase64のテキストを貼り付けてください。",
      masked: true,
      allowNewlines: true,
      validate: { value in
        do {
          _ = try KeyFile.decode(value)
          return nil
        } catch {
          return errorMessage(error)
        }
      }
    )
    return text.flatMap { try? KeyFile.decode($0) }
  }
}
