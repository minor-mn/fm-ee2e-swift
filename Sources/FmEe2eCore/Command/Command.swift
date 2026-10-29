/// キーに割り当てる操作の種類。どのキーがどの操作かは全タブ共通で、操作の中身はタブ（[Pane.commands]）が決める。
enum Operation: Hashable {
  case enter
  case delete
  case chmod
  case touch
  case mkdir
  case rename
  case edit
  case paste
  case compress
  case extract
  case reload
  case goHome
  case toggleHidden
  case goToPath
  case signOut
  case shell

  /// G・F12。右のタブの転送（[Pane.transferCommand]）。
  case transfer
}

/// コマンドに渡す環境。[targets] は [runCommand] で確定済み。
struct CommandContext {
  init(_ workspace: Workspace, _ pane: Pane, _ targets: [Mark]) {
    self.workspace = workspace
    self.pane = pane
    self.targets = targets
  }

  let workspace: Workspace

  /// コマンドを実行するタブ。
  let pane: Pane

  /// 対象。マークが1つ以上あればマークだけ、なければカーソルの項目（1件でも配列）。
  /// [Command.cursorOnly] のコマンドには、いつもカーソルの項目。
  let targets: [Mark]

  var app: App { workspace.app }
}

/// タブの操作。操作ごとのベースクラスが小窓の文言や流れを持ち、タブごとの継承クラスが違いを書く。
/// 対象の確定と、使えるかの確認は [runCommand] が行う。
class Command {
  init() {}

  /// ファンクションキーの帯などに出す名前。
  var label: String { "" }

  /// 書き込む操作か（読むだけの場所では使えない）。
  var writes: Bool { false }

  /// 一覧を読み込み済みのときだけ使えるか。
  var needsReady: Bool { true }

  /// カーソルが親フォルダー（..）でも対象にするか。
  var includesParent: Bool { false }

  /// マークを見ず、いつもカーソルの項目だけを対象にするか。
  var cursorOnly: Bool { false }

  /// 1項目にしか実行できないか。
  var single: Bool { false }

  /// 実行するタブ。ふつうは選んでいるタブ。
  func paneIn(_ workspace: Workspace) -> Pane? { workspace.active }

  func run(_ c: CommandContext) async {}
}

/// [command] を実行する。使えるかを確かめ、対象を確定してから渡す。
func runCommand(_ command: Command, _ workspace: Workspace) async {
  guard let pane = command.paneIn(workspace) else {
    return
  }
  if command.writes, !(await pane.checkWritable()) {
    return
  }
  if command.needsReady && !pane.ready {
    return
  }
  let targets =
    command.cursorOnly
    ? pane.cursorTargets(includeParent: command.includesParent)
    : pane.targetsFor(includeParent: command.includesParent)
  if command.single && targets.count > 1 {
    await workspace.app.showError("1項目だけを選んでください。")
    return
  }
  await command.run(CommandContext(workspace, pane, targets))
}

/// G・F12 を、右のタブの転送（[Pane.transferCommand]）として実行する。
/// 右が Google Drive なら暗号化して転送、SSH なら scp、Git なら Git コマンド。
final class RightTransfer: Command {
  override var needsReady: Bool { false }

  override func run(_ c: CommandContext) async {
    if let command = c.workspace.right.transferCommand {
      await runCommand(command, c.workspace)
    }
  }
}

/// [targets] の数を表す「「名前」」か「N項目」。
func quotedLabel(_ targets: [Mark]) -> String {
  targets.count == 1 ? "「\(targets[0].entry.name)」" : "\(targets.count)項目"
}

/// [name] が決まっていれば [apply] し（失敗はエラーを出す）、その名前にカーソルを合わせて [pane] を読み直す。
func applyName(_ pane: Pane, _ name: String?, _ apply: (String) async throws -> Void) async {
  guard let name else {
    return
  }
  do {
    try await apply(name)
  } catch {
    await pane.app.showError(error)
  }
  await pane.load(focus: name)
}

/// 右の窓に出すもの（Tab で切り替える）。
enum RightMode: CaseIterable { case drive, git, ssh, icloud, local }

/// 左の窓に出すもの（Shift+Tab で切り替える）。
enum LeftMode { case local, ssh }

/// コマンドから見える、メイン画面の今の状態（窓・選んでいる窓・クリップボードなど）。
protocol Workspace: AnyObject {
  var app: App { get }

  /// 左のタブのローカル。左に SSH を出している間も、開いているフォルダーを持ち続ける。
  var local: LocalPane { get }

  /// 右のタブのローカル（左の [local] とは別に、開くフォルダーを持つ）。
  var localRight: LocalPane { get }

  /// 右のタブの iCloud Drive。
  var icloud: ICloudPane { get }
  var drive: DrivePane { get }

  /// 右のタブの SSH。
  var ssh: SshPane { get }

  /// 左のタブの SSH（右の [ssh] とは別に、接続を持つ）。
  var sshLeft: SshPane { get }

  /// git の窓。git が見つかったときだけある。
  var gitPane: GitPane? { get }

  var leftMode: LeftMode { get }
  var rightMode: RightMode { get }

  /// 左に出しているタブ。
  var left: Pane { get }

  /// 選んでいるタブ。
  var active: Pane { get }

  /// 右に出しているタブ。
  var right: Pane { get }

  /// C・M で選んだ項目。
  var clip: Clip? { get set }

  /// 左右の一覧を読み直す。
  func reloadAll() async
}

/// C（複製）・M（移動）で選んだ項目。P で開いているフォルダーに貼り付ける。
class Clip {
  init(move: Bool) {
    self.move = move
  }

  let move: Bool

  var length: Int { 0 }
}

/// ローカルの項目。
final class LocalClip: Clip {
  init(_ paths: [String], move: Bool) {
    self.paths = paths
    super.init(move: move)
  }

  let paths: [String]

  override var length: Int { paths.count }
}

/// SSH の接続先の項目。
final class SshClip: Clip {
  init(_ ssh: Ssh, _ paths: [String], move: Bool) {
    self.ssh = ssh
    self.paths = paths
    super.init(move: move)
  }

  /// 選んだときの接続。別の接続先には貼り付けない。
  let ssh: Ssh

  /// リモートの絶対パス。
  let paths: [String]

  override var length: Int { paths.count }
}

/// Google Drive（アプリ専用のフォルダー）の項目。Google Drive の中にだけ貼り付ける。
final class DriveClip: Clip {
  init(_ items: [(path: String, name: String, isDir: Bool)], move: Bool) {
    self.items = items
    super.init(move: move)
  }

  /// 実際のパス（名前は暗号化したもの）、一覧での名前（復号したもの）、フォルダーかどうか。
  let items: [(path: String, name: String, isDir: Bool)]

  override var length: Int { items.count }
}
