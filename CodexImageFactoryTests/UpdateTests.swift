import Foundation
import Sparkle
import Testing
@testable import CodexImageFactory

@Suite("自動アップデート")
struct UpdateTests {
    @Test func foundUpdatesAreDownloadedButNeverRelaunchImmediately() {
        #expect(SilentUpdatePolicy.choiceForFoundUpdate(stage: .notDownloaded, informationOnly: false) == .install)
        #expect(SilentUpdatePolicy.choiceForFoundUpdate(stage: .downloaded, informationOnly: false) == .install)
        // 終了時のインストールが決まっているときに install を返すと、その場で再起動してしまう。
        #expect(SilentUpdatePolicy.choiceForFoundUpdate(stage: .installing, informationOnly: false) == .dismiss)
        // お知らせだけの更新はダウンロードしない。
        #expect(SilentUpdatePolicy.choiceForFoundUpdate(stage: .notDownloaded, informationOnly: true) == .dismiss)
        // 準備ができても再起動はせず、終了時に任せる。
        #expect(SilentUpdatePolicy.choiceWhenReadyToInstall == .dismiss)
    }

    @Test func stagesMapFromSparkle() {
        #expect(SilentUpdatePolicy.stage(.notDownloaded) == .notDownloaded)
        #expect(SilentUpdatePolicy.stage(.downloaded) == .downloaded)
        #expect(SilentUpdatePolicy.stage(.installing) == .installing)
    }

    @Test func updatesRunOnlyInReleaseBuildsWithAKeyAndAnHTTPSFeed() {
        let ok = UpdateConfiguration(feedURL: "https://kkosuge.github.io/codex-image-factory/appcast.xml", publicEDKey: "abc=", enabledInBuild: true)
        #expect(ok.unavailableReason(isRunningTests: false) == nil)
        #expect(ok.unavailableReason(isRunningTests: true) != nil)

        var debug = ok
        debug.enabledInBuild = false
        #expect(debug.unavailableReason(isRunningTests: false)?.contains("開発用") == true)

        var noKey = ok
        noKey.publicEDKey = ""
        #expect(noKey.unavailableReason(isRunningTests: false)?.contains("鍵") == true)
        noKey.publicEDKey = "$(SPARKLE_PUBLIC_ED_KEY)"
        #expect(noKey.unavailableReason(isRunningTests: false) != nil)

        var http = ok
        http.feedURL = "http://example.com/appcast.xml"
        #expect(http.unavailableReason(isRunningTests: false) != nil)
    }

    @Test func configurationIsReadFromInfoPlistValues() {
        let c = UpdateConfiguration(infoDictionary: [
            "SUFeedURL": " https://example.com/appcast.xml ",
            "SUPublicEDKey": "key=",
            "CIFUpdatesEnabled": "YES",
        ])
        #expect(c == UpdateConfiguration(feedURL: "https://example.com/appcast.xml", publicEDKey: "key=", enabledInBuild: true))
        #expect(!UpdateConfiguration(infoDictionary: ["CIFUpdatesEnabled": "NO"]).enabledInBuild)
        #expect(!UpdateConfiguration(infoDictionary: [:]).enabledInBuild)
    }

    @Test func thisTestHostHasUpdatesTurnedOff() {
        // テストは Debug でビルドする。Debug では自動アップデートを動かさない。
        let c = UpdateConfiguration(infoDictionary: Bundle.main.infoDictionary ?? [:])
        #expect(!c.enabledInBuild)
        #expect(c.feedURL == "https://kkosuge.github.io/codex-image-factory/appcast.xml")
    }

    @Test func statusTextsAreReadable() {
        #expect(UpdateStatus.readyOnQuit(version: "1.2.0").text.contains("終了したときにインストール"))
        #expect(UpdateStatus.downloading(version: "1.2.0", percent: 42).text.contains("42%"))
        #expect(UpdateStatus.idle(lastCheck: nil).text.contains("まだ確認していません"))
        #expect(UpdateStatus.failed("ネットワーク").text.contains("ネットワーク"))
    }

    @MainActor
    @Test func controllerStaysOffInTests() {
        let controller = UpdateController()
        controller.start()
        #expect(!controller.isAvailable)
        #expect(!controller.canCheckNow)
        if case .unavailable = controller.status {} else {
            Issue.record("テスト中は動かない: \(controller.status)")
        }
    }
}
