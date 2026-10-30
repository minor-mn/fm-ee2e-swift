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
    let choice = await c.app.askChoice(tr("drive_setup.title"), [tr("drive_setup.generate_title"), tr("drive_setup.paste_title")])
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
      await c.app.showError(tr("drive_setup.save_failed", ["error": errorMessage(error)]))
      return
    }
    await pane.check()
  }

  private func generate(_ c: CommandContext, _ pane: DrivePane) async -> Data? {
    let ok = await c.app.confirm(
      tr("drive_setup.generate_title"),
      tr("drive_setup.generate_confirm", ["key_file": pane.keyFile]),
      yes: tr("drive_setup.generate_yes")
    )
    return ok ? KeyFile.generate() : nil
  }

  private func paste(_ c: CommandContext) async -> Data? {
    let text = await c.app.input(
      tr("drive_setup.paste_title"),
      message: tr("drive_setup.paste_message", ["header": KeyFile.header]),
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
