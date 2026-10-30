import Foundation

/// 設定ファイルを読む。読めなければ既定の設定（右の窓のタブはすべて on）と、エラーの文。
func loadConfig() async -> (AppConfig, String?) {
  do {
    return (try await AppConfig.load(), nil)
  } catch {
    return (AppConfig(), tr("run_app.config_unreadable", ["error": errorMessage(error)]))
  }
}

/// [host] にメイン画面を出し、終わるまで待つ。[started] でメイン画面を受け取る（Ctrl+C などの終了の要求をつなぐ）。
/// 見つからなかったフォントを、ステータスバーに出す。
func showMissingFonts(_ app: App, _ appearance: Appearance) {
  if !appearance.missingFonts.isEmpty {
    let fonts = appearance.missingFonts.joined(separator: tr("run_app.font_separator"))
    app.showStatus(tr("run_app.missing_fonts", ["fonts": fonts]))
  }
}

func runMain(_ host: Host, _ config: AppConfig, _ configError: String?, started: (MainView) -> Void) async {
  Appearance.current = config.appearance
  let app = App(host)
  // 鍵ファイルなどがなくても、すぐメイン画面を出す（Google Drive のタブが使えないだけ）。
  let main = MainView(app, config: config)
  if let configError {
    // 設定ファイル・文言のファイルを読み込めなかったときは、既定の設定で起動してエラーを出す。
    Task { await app.showError(configError) }
  }
  showMissingFonts(app, config.appearance)
  started(main)
  await app.run(main)
  await deleteOpenTemps()
}
