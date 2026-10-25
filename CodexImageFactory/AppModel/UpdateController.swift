import AppKit
import Foundation
import Observation
import Sparkle

/// 自動アップデートの状態。設定欄に文字で出す（ウィンドウやアラートは出さない）。
enum UpdateStatus: Equatable, Sendable {
    /// このビルドでは自動アップデートを使わない（開発版・鍵が無いなど）。理由を持つ。
    case unavailable(String)
    case idle(lastCheck: Date?)
    case checking
    case upToDate(Date)
    case downloading(version: String, percent: Int?)
    case preparing(version: String)
    /// ダウンロードと準備が終わり、アプリを終了したときに入れ替わる。
    case readyOnQuit(version: String)
    /// ダウンロードしないお知らせだけの更新。
    case informationOnly(version: String)
    case failed(String)

    var text: String {
        switch self {
        case .unavailable(let reason):
            return reason
        case .idle(let lastCheck):
            guard let lastCheck else { return String(localized: "まだ確認していません。1 日に 1 回、自動で確認します。") }
            return String(localized: "最後に確認した日時: \(Self.format(lastCheck))")
        case .checking:
            return String(localized: "アップデートを確認しています…")
        case .upToDate(let date):
            return String(localized: "最新版です（\(Self.format(date)) に確認）")
        case .downloading(let version, let percent):
            if let percent {
                return String(localized: "バージョン \(version) をダウンロードしています（\(percent)%）")
            }
            return String(localized: "バージョン \(version) をダウンロードしています…")
        case .preparing(let version):
            return String(localized: "バージョン \(version) を準備しています…")
        case .readyOnQuit(let version):
            return String(localized: "バージョン \(version) は、アプリを終了したときにインストールされます。")
        case .informationOnly(let version):
            return String(localized: "バージョン \(version) のお知らせがあります（自動ではインストールしません）。GitHub のリリースのページを確認してください。")
        case .failed(let message):
            return String(localized: "アップデートを確認できませんでした: \(message)")
        }
    }

    private static func format(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
    }
}

/// 画面を出さないアップデートの方針。Sparkle に返す選択を決める。
///
/// 裏でダウンロードして準備まで進め、インストールはアプリの終了時に任せる。
/// その場で再起動はしない（実行中のジョブを止めないため）。
enum SilentUpdatePolicy {
    enum Stage: Equatable {
        case notDownloaded
        case downloaded
        case installing
    }

    /// 新しい版が見つかったとき。
    static func choiceForFoundUpdate(stage: Stage, informationOnly: Bool) -> SPUUserUpdateChoice {
        if informationOnly {
            // ダウンロードするものが無い。お知らせとして文字で出すだけにする。
            return .dismiss
        }
        switch stage {
        case .notDownloaded, .downloaded:
            // ダウンロード・展開まで進める。その後の「再起動してインストール」には dismiss を返す。
            return .install
        case .installing:
            // すでに終了時のインストールが決まっている。install を返すとその場で再起動してしまう。
            return .dismiss
        }
    }

    /// 準備が終わり「再起動してインストールするか」を聞かれたとき。終了時のインストールに任せる。
    static let choiceWhenReadyToInstall: SPUUserUpdateChoice = .dismiss

    static func stage(_ stage: SPUUserUpdateStage) -> Stage {
        switch stage {
        case .notDownloaded: .notDownloaded
        case .downloaded: .downloaded
        case .installing: .installing
        @unknown default: .notDownloaded
        }
    }
}

/// 自動アップデートを動かす条件（Info.plist の値から決める）。
struct UpdateConfiguration: Equatable {
    var feedURL: String
    var publicEDKey: String
    var enabledInBuild: Bool

    init(feedURL: String, publicEDKey: String, enabledInBuild: Bool) {
        self.feedURL = feedURL
        self.publicEDKey = publicEDKey
        self.enabledInBuild = enabledInBuild
    }

    init(infoDictionary info: [String: Any]) {
        feedURL = (info["SUFeedURL"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        publicEDKey = (info["SUPublicEDKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let flag = (info["CIFUpdatesEnabled"] as? String ?? "").uppercased()
        enabledInBuild = flag == "YES" || flag == "1" || flag == "TRUE"
    }

    /// 動かせないときの理由。nil なら動かせる。
    func unavailableReason(isRunningTests: Bool) -> String? {
        if isRunningTests {
            return String(localized: "テスト中は自動アップデートを使いません。")
        }
        if !enabledInBuild {
            return String(localized: "開発用のビルドなので、自動アップデートは使いません（配布版でだけ動きます）。")
        }
        if publicEDKey.isEmpty || publicEDKey.hasPrefix("$(") {
            return String(localized: "署名を確かめる鍵が設定されていないため、自動アップデートは使いません。")
        }
        guard let url = URL(string: feedURL), url.scheme == "https" else {
            return String(localized: "アップデート情報の URL が設定されていないため、自動アップデートは使いません。")
        }
        return nil
    }
}

/// 自動アップデート（Sparkle）。状態を文字で持ち、設定欄の文字ボタンから操作する。
@MainActor
@Observable
final class UpdateController {
    private(set) var status: UpdateStatus
    /// 「今すぐ再起動してアップデート」を出せるか（終了時のインストールが決まっているとき）。
    private(set) var canInstallNow = false
    /// 裏で自動ダウンロードするか（Sparkle の設定の写し）。
    private(set) var automaticallyDownloads = false
    let versionText: String

    @ObservationIgnored private let configuration: UpdateConfiguration
    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var userDriver: SilentUserDriver?
    @ObservationIgnored private var updaterDelegate: SilentUpdaterDelegate?
    @ObservationIgnored private var immediateInstall: (() -> Void)?
    @ObservationIgnored private var expectedLength: UInt64 = 0
    @ObservationIgnored private var receivedLength: UInt64 = 0
    @ObservationIgnored private var pendingVersion = ""

    init(bundle: Bundle = .main) {
        let info = bundle.infoDictionary ?? [:]
        configuration = UpdateConfiguration(infoDictionary: info)
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        versionText = String(localized: "バージョン \(short)（ビルド \(build)）")
        status = .unavailable(
            configuration.unavailableReason(isRunningTests: RuntimeEnvironment.isRunningTests)
                ?? String(localized: "自動アップデートを準備しています…")
        )
    }

    var isAvailable: Bool { updater != nil }

    /// 確認ボタンを押せるか。
    var canCheckNow: Bool {
        guard let updater else { return false }
        if case .checking = status { return false }
        return updater.canCheckForUpdates
    }

    /// アプリの起動が終わったら呼ぶ。条件がそろっていなければ何もしない。
    func start() {
        guard updater == nil else { return }
        if let reason = configuration.unavailableReason(isRunningTests: RuntimeEnvironment.isRunningTests) {
            status = .unavailable(reason)
            return
        }
        let driver = SilentUserDriver(controller: self)
        let delegate = SilentUpdaterDelegate(controller: self)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: delegate)
        do {
            try updater.start()
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        self.updater = updater
        userDriver = driver
        updaterDelegate = delegate
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
        status = .idle(lastCheck: updater.lastUpdateCheckDate)
    }

    /// 「アップデートを確認」。
    func checkNow() {
        guard let updater, updater.canCheckForUpdates else { return }
        status = .checking
        updater.checkForUpdates()
    }

    /// 「アップデートを自動でダウンロードする」の切り替え。
    func setAutomaticallyDownloads(_ value: Bool) {
        guard let updater else { return }
        updater.automaticallyDownloadsUpdates = value
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
    }

    /// 「今すぐ再起動してアップデート」。実行中のジョブが無いときだけ画面から呼ぶ。
    func installNowAndRelaunch() {
        guard canInstallNow, let immediateInstall else { return }
        immediateInstall()
    }

    // MARK: - Sparkle からの知らせ

    fileprivate func userInitiatedCheckStarted() {
        status = .checking
    }

    fileprivate func updateFound(version: String, informationOnly: Bool, stage: SilentUpdatePolicy.Stage) {
        pendingVersion = version
        if informationOnly {
            status = .informationOnly(version: version)
        } else if stage == .installing {
            status = .readyOnQuit(version: version)
        } else {
            status = .downloading(version: version, percent: nil)
        }
    }

    fileprivate func noUpdateFound() {
        status = .upToDate(Date())
    }

    fileprivate func failed(_ error: Error) {
        status = .failed(error.localizedDescription)
    }

    fileprivate func downloadStarted() {
        expectedLength = 0
        receivedLength = 0
        status = .downloading(version: pendingVersion, percent: nil)
    }

    fileprivate func downloadExpected(_ length: UInt64) {
        expectedLength = length
    }

    fileprivate func downloadReceived(_ length: UInt64) {
        receivedLength += length
        let percent = expectedLength > 0 ? Int(min(100, receivedLength * 100 / expectedLength)) : nil
        status = .downloading(version: pendingVersion, percent: percent)
    }

    fileprivate func preparing() {
        status = .preparing(version: pendingVersion)
    }

    fileprivate func readyOnQuit(version: String?, immediateInstall: (() -> Void)?) {
        if let version, !version.isEmpty {
            pendingVersion = version
        }
        if let immediateInstall {
            self.immediateInstall = immediateInstall
            canInstallNow = true
        }
        status = .readyOnQuit(version: pendingVersion)
    }

    fileprivate func cycleFinished(error: Error?) {
        if let updater {
            automaticallyDownloads = updater.automaticallyDownloadsUpdates
        }
        // 進行中の表示（ダウンロード・準備・終了時のインストール待ち）は残す。
        switch status {
        case .checking, .idle:
            if let error, (error as NSError).code != Int(SUError.noUpdateError.rawValue) {
                status = .failed(error.localizedDescription)
            } else if error != nil {
                status = .upToDate(Date())
            } else {
                status = .idle(lastCheck: updater?.lastUpdateCheckDate)
            }
        default:
            break
        }
    }

    fileprivate func dismissed() {
        switch status {
        case .readyOnQuit, .informationOnly, .failed, .upToDate:
            break
        default:
            status = .idle(lastCheck: updater?.lastUpdateCheckDate)
        }
    }
}

/// Sparkle の表示部品の代わり。ウィンドウもアラートも出さず、状態を UpdateController に渡すだけ。
@MainActor
private final class SilentUserDriver: NSObject, SPUUserDriver {
    weak var controller: UpdateController?

    init(controller: UpdateController) {
        self.controller = controller
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // 確認は自動で行う。システム情報は送らない。
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        controller?.userInitiatedCheckStarted()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let stage = SilentUpdatePolicy.stage(state.stage)
        controller?.updateFound(
            version: appcastItem.displayVersionString,
            informationOnly: appcastItem.isInformationOnlyUpdate,
            stage: stage
        )
        reply(SilentUpdatePolicy.choiceForFoundUpdate(stage: stage, informationOnly: appcastItem.isInformationOnlyUpdate))
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        controller?.noUpdateFound()
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        controller?.failed(error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        controller?.downloadStarted()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        controller?.downloadExpected(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        controller?.downloadReceived(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        controller?.preparing()
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        controller?.readyOnQuit(version: nil, immediateInstall: nil)
        reply(SilentUpdatePolicy.choiceWhenReadyToInstall)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        controller?.dismissed()
    }
}

/// Sparkle の delegate。裏でダウンロードした更新を「終了時にインストール」として受け取る。
@MainActor
private final class SilentUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    weak var controller: UpdateController?

    init(controller: UpdateController) {
        self.controller = controller
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        // true を返すと、今すぐ入れ替えるタイミングをこちらで選べる（「今すぐ再起動してアップデート」）。
        // どちらにしても、アプリを終了したときにはインストールされる。
        controller?.readyOnQuit(version: item.displayVersionString, immediateInstall: immediateInstallHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        controller?.cycleFinished(error: error)
    }
}
