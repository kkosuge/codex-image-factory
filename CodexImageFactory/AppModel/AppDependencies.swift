import AppKit
import Foundation

/// AppModel から見たキュー。本番は JobQueue、テストではダミーに差し替える。
protocol JobQueueing: Sendable {
    /// キューからの通知。読むのは AppModel だけ。
    var events: AsyncStream<QueueEvent> { get }
    func updateSettings(_ settings: AppSettings) async
    func enqueue(_ jobs: [JobRecord]) async
    func restore(_ jobs: [JobRecord]) async
    func update(_ job: JobRecord) async -> Bool
    func remove(_ id: UUID) async -> Bool
    func moveUp(_ id: UUID) async
    func moveDown(_ id: UUID) async
    func cancel(_ id: UUID) async
    func pause() async
    func resume() async
    func snapshot() async -> QueueSnapshot
    func shutdown(timeout: TimeInterval) async
}

extension JobQueue: JobQueueing {}

/// AppModel が外の世界に触る部分。テストでは全部ダミーにして、ユーザーのファイルに触れない。
struct AppDependencies {
    var settingsStore: SettingsStore
    /// キューを作る。引数は起動時の設定（codex のパスは手入力の値。自動検出の結果はあとで updateSettings で渡す）。
    var makeQueue: @MainActor (AppSettings) -> any JobQueueing
    /// 前回終了時に保存した待機中ジョブ。
    var loadSavedQueue: @Sendable () -> [JobRecord]
    /// 履歴を読む（メインスレッド外で呼ぶ）。
    var loadHistory: @Sendable (URL) -> [JobRecord]
    /// 終わったジョブを履歴の索引に足す（メインスレッド外で呼ぶ）。
    var registerHistory: @Sendable (JobRecord) -> Void
    /// 履歴から消す（画像は残す。メインスレッド外で呼ぶ）。実行中・待機中のジョブの記録には呼ばないこと。
    var deleteHistory: @Sendable (JobRecord) throws -> Void
    /// stdout.jsonl と stderr.log を読む（メインスレッド外で呼ぶ）。
    var readLogs: @Sendable (URL) -> (stdout: String, stderr: String)
    /// ログインシェルで codex を探す（結果は覚えておく）。
    var detectCodexPath: @Sendable () async -> String?
    /// 覚えた検出結果を捨てる。
    var invalidateCodexDetection: @Sendable () async -> Void
    /// 子プロセス用の環境変数。
    var codexEnvironment: @Sendable () async -> [String: String]
    /// `codex login status` を実行する。
    var loginStatus: @Sendable (_ codexPath: String, _ environment: [String: String]) async -> LoginStatus
    /// 実行できる通常ファイルか（フォルダは false）。
    var isExecutableFile: @Sendable (String) -> Bool
    /// `~` の展開先。
    var homeDirectory: URL
    var notifier: any AppNotifying
    var copyToPasteboard: @MainActor (String) -> Void
    var openFile: @MainActor (URL) -> Void
    var revealInFinder: @MainActor ([URL]) -> Void
    /// フォルダを作る（「Finder で開く」で出力ディレクトリがまだ無いとき）。
    var createDirectory: @Sendable (URL) throws -> Void
    var now: @Sendable () -> Date
}

extension AppDependencies {
    /// 本番用。
    @MainActor
    static func live() -> AppDependencies {
        let history = HistoryStore.default
        let queueStore = QueueStore.default
        return AppDependencies(
            settingsStore: SettingsStore(defaults: .standard),
            makeQueue: { settings in
                JobQueue(executor: JobExecutor(runner: ProcessCodexRunner()), store: queueStore, settings: settings)
            },
            loadSavedQueue: { queueStore.load() },
            loadHistory: { history.loadAll(outputDirectory: $0) },
            registerHistory: { history.register($0) },
            // AppModel.deleteHistory が、自分のキューで実行中・待機中でないことを確かめてから呼ぶ。
            // そのため run.json が「実行中」のまま残った記録（前回の異常終了）も消してよい。
            deleteHistory: { try history.delete($0, allowingInterrupted: true) },
            readLogs: { RunFolder.readLogs(folder: $0) },
            detectCodexPath: { await CodexEnvironmentCache.shared.detectedCodexPath() },
            invalidateCodexDetection: { await CodexEnvironmentCache.shared.invalidate() },
            codexEnvironment: { await CodexEnvironmentCache.shared.environment() },
            loginStatus: { path, env in await CodexEnvironment.loginStatus(codexPath: path, environment: env) },
            // フォルダは実行できないので外す（FileManager.isExecutableFile はフォルダにも true を返す）。
            isExecutableFile: { CodexEnvironment.isExecutableFile($0) },
            homeDirectory: PathUtil.homeDirectory,
            notifier: UserNotificationNotifier(),
            copyToPasteboard: { text in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            },
            openFile: { url in
                _ = NSWorkspace.shared.open(url)
            },
            revealInFinder: { urls in
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            },
            createDirectory: { url in
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            },
            now: { Date() }
        )
    }
}
