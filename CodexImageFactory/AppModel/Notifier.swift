import Foundation
import UserNotifications

/// macOS 通知。テストではダミーに差し替える。
protocol AppNotifying: Sendable {
    /// 通知の許可を求める。失敗しても何もしない。
    func requestAuthorization() async
    /// 通知を 1 件出す。出せなくても何もしない。
    func post(title: String, body: String) async
}

/// UserNotifications を使う本番用の通知。
///
/// アプリは ad-hoc 署名なので、許可の要求や通知の追加が失敗することがある。その場合は通知なしで動かす。
struct UserNotificationNotifier: AppNotifying {
    func requestAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            // 許可が取れなくてもアプリの動作には関係しない。
        }
    }

    func post(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // 通知が出せなくてもアプリの動作には関係しない。
        }
    }
}
