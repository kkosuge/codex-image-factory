import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexImageFactory

/// README 用のスクリーンショットを書き出す。普段は動かさない。
///
/// ```
/// TEST_RUNNER_CIF_SCREENSHOT_DIR=docs/images TEST_RUNNER_CIF_SCREENSHOT_ASSETS=/path/to/pngs \
///   xcodebuild ... test -only-testing:CodexImageFactoryTests/ScreenshotTests -testLanguage en -testRegion US
/// ```
///
/// `CIF_SCREENSHOT_ASSETS` には robot-mascot.png / cat-sticker.png / hero-bg.png / leaf-illust.png / app-icon.png を置く
/// （本物の codex で作った画像を使う）。無ければ単色の画像で代用する。
@Suite(
    "Screenshots",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["CIF_SCREENSHOT_DIR"] != nil, "CIF_SCREENSHOT_DIR のときだけ動かす")
)
@MainActor
struct ScreenshotTests {
    struct Sample {
        var slug: String
        var prompt: String
        var asset: String
        var aspect: ImageAspect
        var background: ImageBackground
    }

    static var isEnglish: Bool {
        (Locale.preferredLanguages.first ?? "").hasPrefix("en")
    }

    static var samples: [Sample] {
        if isEnglish {
            return [
                Sample(slug: "robot-mascot", prompt: "A round robot mascot character. Flat vector illustration with soft colors.", asset: "robot-mascot", aspect: .square, background: .transparent),
                Sample(slug: "cat-sticker", prompt: "A sleepy cat sticker with a thick white outline and simple lines.", asset: "cat-sticker", aspect: .square, background: .transparent),
                Sample(slug: "hero-bg", prompt: "An abstract hero background for a website. Pale blue-to-purple gradient with gentle waves.", asset: "hero-bg", aspect: .landscape, background: .unspecified),
                Sample(slug: "leaf-illust", prompt: "A single leaf in watercolor, with generous margins.", asset: "leaf-illust", aspect: .portrait, background: .white),
            ]
        }
        return [
            Sample(slug: "robot-mascot", prompt: "丸いロボットのマスコットキャラクター。フラットなベクターイラスト、やわらかい配色。", asset: "robot-mascot", aspect: .square, background: .transparent),
            Sample(slug: "cat-sticker", prompt: "眠そうな猫のステッカー。太めの白いふち取り、シンプルな線。", asset: "cat-sticker", aspect: .square, background: .transparent),
            Sample(slug: "hero-bg", prompt: "Web サイトのヒーロー用の抽象的な背景。淡い青と紫のグラデーション、ゆるい波の形。", asset: "hero-bg", aspect: .landscape, background: .unspecified),
            Sample(slug: "leaf-illust", prompt: "1 枚の葉っぱの水彩イラスト。余白を広めに。", asset: "leaf-illust", aspect: .portrait, background: .white),
        ]
    }

    static var runningPrompt: (String, String) {
        isEnglish
            ? ("app-icon", "An app icon for an image generator. A factory combined with a camera, rounded square.")
            : ("app-icon", "画像生成アプリのアイコン。工場とカメラを組み合わせたモチーフ、角丸の正方形。")
    }

    static var queuedPrompts: [(String, String)] {
        isEnglish
            ? [("treasure-chest", "A pixel-art treasure chest sprite, 32x32 style."), ("coffee-shop", "An isometric illustration of a small coffee shop.")]
            : [("treasure-chest", "ドット絵の宝箱のスプライト。32x32 風。"), ("coffee-shop", "小さなコーヒーショップのアイソメトリックなイラスト。")]
    }

    static var draftPrompt: String {
        isEnglish
            ? "A friendly ghost sticker, pastel colors\n\nA hand-drawn map icon\n\nA paper airplane, line art"
            : "やさしいおばけのステッカー。パステルカラー\n\n手描き風の地図のアイコン\n\n紙飛行機の線画"
    }

    @Test func renderReadmeScreenshots() async throws {
        let env = ProcessInfo.processInfo.environment
        let outDir = URL(fileURLWithPath: try #require(env["CIF_SCREENSHOT_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let lang = Self.isEnglish ? "en" : "ja"

        let h = try UITHarness()
        defer { h.cleanUp() }
        h.detectedPath = "/opt/homebrew/bin/codex"
        // README に一時フォルダや個人のパスが写らないよう、共有フォルダに置いて終わったら消す。
        let outputRoot = URL(fileURLWithPath: "/Users/Shared/CodexImages", isDirectory: true)
        // 既にあるフォルダは消さない（人のファイルかもしれない）。
        try #require(!FileManager.default.fileExists(atPath: outputRoot.path), "\(outputRoot.path) がすでにあるので撮れません")
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputRoot) }
        var settings = AppSettings.defaults
        settings.outputDirectory = outputRoot.path
        h.saveSettings(settings)

        // 履歴（実際に生成した画像を使う）。
        let now = Date()
        var history: [JobRecord] = []
        for (i, sample) in Self.samples.enumerated() {
            let started = now.addingTimeInterval(Double(-600 - i * 240))
            let folder = outputRoot.appendingPathComponent("\(Slug.timestamp(started))-\(sample.slug)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let image = folder.appendingPathComponent("\(sample.slug)-01.png")
            try Self.copyAsset(named: sample.asset, assets: env["CIF_SCREENSHOT_ASSETS"], to: image)
            var job = JobRecord(
                createdAt: started.addingTimeInterval(-3),
                slug: sample.slug,
                prompt: sample.prompt,
                preset: "",
                count: 1,
                aspect: sample.aspect,
                background: sample.background
            )
            job.status = .done
            job.startedAt = started
            job.finishedAt = started.addingTimeInterval(Double(58 + i * 3))
            job.fullPrompt = PromptBuilder.fullPrompt(for: job, template: AppSettings.defaultInstructionTemplate)
            let options = CommandBuilder.Options(codexPath: "/opt/homebrew/bin/codex", workingDirectory: folder.path, prompt: job.fullPrompt)
            job.command = CommandBuilder.command(options)
            job.commandLine = CommandBuilder.commandLine(options)
            job.exitCode = 0
            job.outputDir = folder.path
            job.images = [image.path]
            job.lastMessage = "\(sample.slug)-01.png"
            job.codexThreadId = "01a16e98-b283-71f2-a25e-49a5257f79b\(i)"
            history.append(job)
        }
        h.historyRecords = history

        var deps = h.dependencies()
        let sampleLog = Self.sampleLog(slug: Self.samples[0].slug)
        deps.readLogs = { _ in (stdout: sampleLog, stderr: "") }
        let model = AppModel(dependencies: deps)

        let (window, hosting) = Self.makeWindow(ContentView(model: model))
        defer { window.close() }
        model.start()
        #expect(await uitWaitUntil(timeout: .seconds(5)) { model.history.count == Self.samples.count })

        // キュー: 実行中 1 件・待機中 2 件。
        var running = JobRecord(createdAt: now.addingTimeInterval(-50), slug: Self.runningPrompt.0, prompt: Self.runningPrompt.1, preset: "", count: 1, aspect: .square, background: .unspecified)
        running.status = .running
        running.startedAt = now.addingTimeInterval(-42)
        let queued = Self.queuedPrompts.enumerated().map { i, item in
            JobRecord(createdAt: now.addingTimeInterval(Double(-30 + i * 10)), slug: item.0, prompt: item.1, preset: "", count: 2, aspect: .square, background: .transparent)
        }
        h.queue.emit(.snapshot(QueueSnapshot(queued: queued, running: [running], isPaused: false, concurrency: 3)))
        #expect(await uitWaitUntil(timeout: .seconds(5)) { model.running.count == 1 && model.queued.count == 2 })

        model.draft.prompt = Self.draftPrompt
        model.select(history[0].id)
        try await Self.settle(hosting, seconds: 2.5)
        try Self.write(hosting, to: outDir.appendingPathComponent("screenshot-main-\(lang).png"))

        // 設定を開いた画面。
        model.showSettings()
        try await Self.settle(hosting, seconds: 1.5)
        try Self.write(hosting, to: outDir.appendingPathComponent("screenshot-settings-\(lang).png"))
    }

    // MARK: - 補助

    static func sampleLog(slug: String) -> String {
        [
            #"{"type":"thread.started","thread_id":"01a16e98-b283-71f2-a25e-49a5257f79b0"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Generating one transparent square mascot with the image generation tool and saving it as \#(slug)-01.png."}}"#,
            #"{"type":"item.completed","item":{"id":"item_2","type":"command_execution","command":"/bin/zsh -lc 'cp ~/.codex/generated_images/01a16e98/exec-df1cd12b.png ./\#(slug)-01.png'","aggregated_output":"","exit_code":0,"status":"completed"}}"#,
            #"{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"\#(slug)-01.png"}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":165414,"cached_input_tokens":141312,"output_tokens":685}}"#,
        ].joined(separator: "\n")
    }

    static func copyAsset(named name: String, assets: String?, to url: URL) throws {
        if let assets {
            let source = URL(fileURLWithPath: assets).appendingPathComponent("\(name).png")
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: url)
                return
            }
        }
        _ = try UIAuditTests.writePNG(in: url.deletingLastPathComponent(), name: url.lastPathComponent, color: .systemTeal)
    }

    static func makeWindow<V: View>(_ view: V) -> (NSWindow, NSHostingView<some View>) {
        // README 用なので、システムがダークモードでもライトで撮る。画面外の描画では窓の背景が透明になるので塗っておく。
        let root = view
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: .aqua)
        let frame = NSRect(x: -20000, y: -20000, width: 1440, height: 900)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrame(frame, display: false)
        window.orderBack(nil)
        return (window, hosting)
    }

    static func settle(_ view: NSView, seconds: Double) async throws {
        let end = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < end {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    static func write(_ view: NSView, to url: URL) throws {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
