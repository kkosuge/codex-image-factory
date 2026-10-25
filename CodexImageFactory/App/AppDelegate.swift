import AppKit
import UserNotifications

/// アプリの終了処理と通知の表示。AppModel もここで 1 つだけ作る。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// ユニットテストのホストとして起動したときは作らない（ユーザーのキュー・履歴・設定に触れないため）。
    /// 同じアプリがすでに動いているときも作らない（2 つ目は前面に出して終わる）。
    private(set) lazy var model: AppModel? = RuntimeEnvironment.isRunningTests || Self.otherInstance != nil
        ? nil
        : AppModel(dependencies: .live())

    /// 自動アップデート（Sparkle）。配布版で鍵が設定されているときだけ動く。
    let updates = UpdateController()

    private var isShuttingDown = false

    /// すでに動いている同じアプリ。2 つ動くと queue.json や履歴、実行中のフォルダを取り合うので、1 つに限る
    /// （Xcode から起動した版と /Applications の版も、バンドル ID が同じなので 1 つに限られる）。
    static let otherInstance: NSRunningApplication? = {
        guard !RuntimeEnvironment.isRunningTests, let id = Bundle.main.bundleIdentifier else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first { $0.processIdentifier != me && !$0.isTerminated }
    }()

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let other = Self.otherInstance else { return }
        other.activate()
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !RuntimeEnvironment.isRunningTests, Self.otherInstance == nil else { return }
        // アプリが前面にあるときも通知を出すため。
        UNUserNotificationCenter.current().delegate = self
        // 1 日 1 回、裏でアップデートを確認する。見つかればダウンロードし、終了時に入れ替える。
        updates.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.needsGracefulShutdown else { return .terminateNow }
        guard !isShuttingDown else { return .terminateCancel }
        isShuttingDown = true
        // 実行中のジョブを止め、追加待ちのジョブもキューに入れて、待機中一覧を保存してから終わる（最大 5 秒）。
        Task {
            await model.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 反映を待っている固定の指示文を保存する。
        model?.flushPendingSettingsEdits()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
