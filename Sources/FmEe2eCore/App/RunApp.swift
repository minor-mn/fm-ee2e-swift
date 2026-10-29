import Darwin

/// アプリを起動し、終わるまで待つ。終了コードを返す。
public func runFmEe2e() async -> Int32 {
  let terminal = Terminal()
  // 設定ファイルを読めなければ、既定の設定（右の窓のタブはすべて on）で起動して、エラーを出す。
  var config = AppConfig()
  var configError: String?
  do {
    config = try await AppConfig.load()
  } catch {
    configError = errorMessage(error)
  }
  do {
    try terminal.start()
  } catch {
    writeStderr("\(errorMessage(error))\n")
    return 1
  }
  let app = App(terminal)
  // 鍵ファイルなどがなくても、すぐメイン画面を出す（Google Drive のタブが使えないだけ）。
  let main = MainView(app, config: config)
  if let configError {
    Task { await app.showError("~/.config/fm-ee2e/config.yml を読み込めません。\n\(configError)") }
  }
  // Ctrl+C はメイン画面では終了の確認を出す。実行したプログラムの中で押した分は無視する。
  let sigint = watchSignal(SIGINT) {
    if !terminal.suspended {
      main.requestQuit()
    }
  }
  await app.run(main)
  sigint.cancel()
  await deleteOpenTemps()
  terminal.restore()
  return 0
}
