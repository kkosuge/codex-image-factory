import SwiftUI

/// ウィンドウ上部のバナー。アラートやシートは使わず、普通のビューとして積む。
struct BannerStack: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            codexBanner
            if let notice = model.rateLimitNotice {
                AppBanner(
                    tone: .warning,
                    title: "レート制限らしきエラーを検出したため、キューを一時停止しました。",
                    message: rateLimitMessage(notice),
                    identifier: "banner.rateLimit"
                ) {
                    Button("再開") { Task { await model.resumeAll() } }
                        .disabled(model.isResumePending)
                        .axControl("キューを再開", id: "banner.rateLimit.resume")
                    Button("閉じる") { model.dismissRateLimitNotice() }
                        .axControl("レート制限のお知らせを閉じる", id: "banner.rateLimit.dismiss")
                }
            }
            if let restored = model.restoredNotice {
                AppBanner(
                    tone: .info,
                    title: restored,
                    message: model.isResumePending ? AppModel.resumeWaitingText : nil,
                    identifier: "banner.restored"
                ) {
                    Button("再開") { Task { await model.resumeAll() } }
                        .disabled(model.isResumePending)
                        .axControl("キューを再開", id: "banner.restored.resume")
                    Button("閉じる") { model.dismissRestoredNotice() }
                        .axControl("復元のお知らせを閉じる", id: "banner.restored.dismiss")
                }
            }
            ForEach(Array(model.notices.enumerated()), id: \.element.id) { index, notice in
                AppBanner(tone: .error, title: notice.text, message: nil, identifier: "banner.notice.\(index)") {
                    Button("閉じる") { model.dismissNotice(notice.id) }
                        .axControl("お知らせを閉じる: \(notice.text)", id: "banner.notice.\(index).dismiss")
                }
            }
        }
    }

    @ViewBuilder
    private var codexBanner: some View {
        switch model.codexCheck {
        case .missing:
            AppBanner(
                tone: .error,
                title: "codex が見つかりません。",
                message: "Codex CLI をインストールするか（例: npm install -g @openai/codex、mise use -g codex）、"
                    + "「設定」の「codex のパス」に codex の絶対パスを入力してください。インストールしたら「再確認」を押してください。",
                identifier: "banner.codexMissing"
            ) {
                codexBannerButtons(prefix: "banner.codexMissing")
            }
        case .invalidPath(let path):
            AppBanner(
                tone: .error,
                title: "codex が見つかりません（指定したパスを実行できません）。",
                message: "指定したパス: \(path)\n「設定」の「codex のパス」を直すか、空欄にして自動検出を使ってください。",
                identifier: "banner.codexMissing"
            ) {
                codexBannerButtons(prefix: "banner.codexMissing")
            }
        case .launchFailed(let path, let output):
            AppBanner(
                tone: .error,
                title: "codex を起動できません（または応答がありません）。",
                message: "codex login status を実行できませんでした（\(path)）。ログインの問題ではありません。\n"
                    + "\(output.isEmpty ? "（出力なし）" : output)\n\n"
                    + "「設定」の「codex のパス」を確かめるか、「codex を探し直す」を押してください。",
                identifier: "banner.codexLaunch"
            ) {
                Button("codex を探し直す") { model.rediscoverCodex() }
                    .axControl("codex を探し直す（ログインシェルで探してログイン状態を再確認）", id: "banner.codexLaunch.rediscover")
                Button("設定を表示") { model.showSettings() }
                    .axControl("設定を表示", id: "banner.codexLaunch.showSettings")
            }
        case .notLoggedIn(_, let output):
            AppBanner(
                tone: .warning,
                title: "Codex にログインしていません。",
                message: "codex login status の結果:\n\(output.isEmpty ? "（出力なし）" : output)\n\n"
                    + "ターミナルで codex login を実行してから「再確認」を押してください。",
                identifier: "banner.login"
            ) {
                Button("ログイン状態を再確認") { model.recheckLogin() }
                    .axControl("ログイン状態を再確認", id: "banner.login.recheck")
            }
        case .idle, .checking, .loggedIn:
            EmptyView()
        }
    }

    @ViewBuilder
    private func codexBannerButtons(prefix: String) -> some View {
        Button("再確認") { model.recheckLogin() }
            .axControl("codex を探し直してログイン状態を再確認", id: "\(prefix).recheck")
        Button("設定を表示") { model.showSettings() }
            .axControl("設定を表示", id: "\(prefix).showSettings")
    }

    private func rateLimitMessage(_ notice: RateLimitNotice) -> String {
        let job = notice.slug.isEmpty ? "" : "ジョブ「\(notice.slug)」: "
        let waiting = model.isResumePending ? "\n\(AppModel.resumeWaitingText)" : ""
        return "\(job)\(notice.message)\n時間をおいてから「再開」を押してください（自動では再試行しません）。\(waiting)"
    }
}

/// バナー 1 枚。状態は文字で書き、アイコンは飾り。
struct AppBanner<Actions: View>: View {
    enum Tone {
        case info
        case warning
        case error

        var symbol: String {
            switch self {
            case .info: "info.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            }
        }

        var tint: Color {
            switch self {
            case .info: .blue
            case .warning: .orange
            case .error: .red
            }
        }
    }

    let tone: Tone
    let title: String
    let message: String?
    let identifier: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tone.symbol)
                .font(.title3)
                .foregroundStyle(tone.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                actions()
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.tint.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
