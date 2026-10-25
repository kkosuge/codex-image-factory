import SwiftUI

/// 設定の「アップデート」。状態は文字で出し、操作は文字ボタンだけ（Sparkle のウィンドウは出さない）。
struct UpdateSettings: View {
    let model: AppModel
    @Environment(UpdateController.self) private var updates: UpdateController?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldTitle("アップデート")
            if let updates {
                content(updates)
            } else {
                Text("このウィンドウでは自動アップデートを使いません。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.update.status")
            }
        }
    }

    /// 実行中のジョブがあるか（あるときは今すぐの再起動をさせない）。
    private var hasActiveJobs: Bool {
        !model.running.isEmpty || (!model.queued.isEmpty && !model.isPaused)
    }

    @ViewBuilder
    private func content(_ updates: UpdateController) -> some View {
        Text(updates.versionText)
            .font(.callout)
            .textSelection(.enabled)
            .accessibilityIdentifier("settings.update.version")
        Text(updates.status.text)
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings.update.status")
        if updates.isAvailable {
            HStack(spacing: 8) {
                Button("アップデートを確認") { updates.checkNow() }
                    .disabled(!updates.canCheckNow)
                    .axControl("アップデートを確認", id: "settings.update.check")
                if updates.canInstallNow {
                    Button("今すぐ再起動してアップデート") { updates.installNowAndRelaunch() }
                        .disabled(hasActiveJobs)
                        .axControl("今すぐ再起動してアップデート（実行中のジョブが無いときだけ）", id: "settings.update.installNow")
                }
            }
            if updates.canInstallNow, hasActiveJobs {
                Text("実行中や待機中のジョブがあるので、今すぐの再起動はできません。終わったら押すか、アプリを終了したときに入れ替わります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.update.installNow.note")
            }
            Toggle(
                "新しい版を自動でダウンロードし、アプリを終了したときにインストールする",
                isOn: Binding(
                    get: { updates.automaticallyDownloads },
                    set: { updates.setAutomaticallyDownloads($0) }
                )
            )
            .toggleStyle(.checkbox)
            .axControl("新しい版を自動でダウンロードし、アプリを終了したときにインストールする", id: "settings.update.auto")
            Text("確認は 1 日に 1 回、自動で行います。アップデートのためのウィンドウは出しません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
