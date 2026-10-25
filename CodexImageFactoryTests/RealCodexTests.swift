import Foundation
import Synchronization
import Testing
@testable import CodexImageFactory

/// 本物の codex を使う受け入れテスト。サブスクリプションの枠を使うので、普段は動かさない。
///
/// ```
/// TEST_RUNNER_CIF_REAL_CODEX=1 TEST_RUNNER_CIF_REAL_OUTPUT_DIR=/path/to/out \
///   xcodebuild -project CodexImageFactory.xcodeproj -scheme CodexImageFactory \
///   -destination 'platform=macOS,arch=arm64' test -only-testing:CodexImageFactoryTests/RealCodexTests
/// ```
@Suite(
    "RealCodex",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["CIF_REAL_CODEX"] == "1", "CIF_REAL_CODEX=1 のときだけ動かす")
)
struct RealCodexTests {
    static var outputDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["CIF_REAL_OUTPUT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: PathUtil.expandTilde(dir), isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("cif-real-\(UUID().uuidString)", isDirectory: true)
    }

    @Test(.timeLimit(.minutes(20)))
    func fivePromptsWithConcurrencyThree() async throws {
        // GUI から起動したときと同じく、ログインシェル経由で codex を探す。
        let codexPath = try #require(await CodexEnvironment.resolveCodexPath(), "codex が見つからない")
        let environment = await CodexEnvironmentCache.shared.environment()
        let login = await CodexEnvironment.loginStatus(codexPath: codexPath, environment: environment)
        #expect(login.loggedIn, "codex にログインしていない: \(login.output)")
        print("codex: \(codexPath) / login: \(login.output)")

        let out = Self.outputDirectory
        var settings = AppSettings.defaults
        settings.outputDirectory = out.path
        settings.codexPath = codexPath
        settings.concurrency = 3
        let queue = JobQueue(executor: JobExecutor(runner: ProcessCodexRunner()), store: nil, settings: settings)

        let finished = Mutex<[JobRecord]>([])
        let maxRunning = Mutex(0)
        let rateLimited = Mutex(false)
        let consumer = Task {
            for await event in queue.events {
                switch event {
                case .snapshot(let s):
                    maxRunning.withLock { $0 = max($0, s.running.count) }
                case .finished(let r):
                    finished.withLock { $0.append(r) }
                    print("finished: \(r.status.label) · \(r.slug) · \(r.images.joined(separator: ", ")) \(r.errorSummary ?? "")")
                case .rateLimited(_, let message):
                    rateLimited.withLock { $0 = true }
                    print("rate limited: \(message)")
                default:
                    break
                }
            }
        }
        defer { consumer.cancel() }

        let prompts = [
            ("robot-mascot", "丸いロボットのマスコットキャラクター。フラットなベクターイラスト、やわらかい配色。", ImageAspect.square, ImageBackground.transparent),
            ("cat-sticker", "眠そうな猫のステッカー。太めの白いふち取り、シンプルな線。", .square, .transparent),
            ("app-icon", "画像生成アプリのアイコン。工場とカメラを組み合わせたモチーフ、角丸の正方形。", .square, .unspecified),
            ("hero-bg", "Web サイトのヒーロー用の抽象的な背景。淡い青と紫のグラデーション、ゆるい波の形。", .landscape, .unspecified),
            ("leaf-illust", "1 枚の葉っぱの水彩イラスト。余白を広めに。", .portrait, .white),
        ]
        let template = settings.instructionTemplate
        let jobs = prompts.compactMap { slug, prompt, aspect, background in
            JobFactory.single(
                from: JobDraft(prompt: prompt, slug: slug, count: 1, aspect: aspect, background: background),
                preset: "",
                template: template,
                now: Date()
            )
        }
        #expect(jobs.count == 5)
        await queue.enqueue(jobs)

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(15 * 60)
        while finished.withLock({ $0.count }) < 5, !rateLimited.withLock({ $0 }), clock.now < deadline {
            try await Task.sleep(for: .seconds(1))
        }
        let records = finished.withLock { $0 }
        #expect(records.count == 5)
        #expect(maxRunning.withLock { $0 } == 3)
        #expect(Set(records.map(\.outputDir)).count == records.count, "ジョブごとに別フォルダ")
        for r in records {
            #expect(r.status == .done, "\(r.slug): \(r.errorSummary ?? "")")
            let folder = URL(fileURLWithPath: r.outputDir)
            for name in ["run.json", "prompt.txt", "stdout.jsonl", "stderr.log", "last-message.md"] {
                #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "\(r.slug): \(name)")
            }
            #expect(!r.images.isEmpty, "\(r.slug): 画像が無い")
            #expect(r.images.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        }

        // 履歴の「コマンドをコピー」の文字列を、そのままシェルに貼った想定で実行する。
        let first = try #require(records.first { $0.status == .done })
        let image = try #require(first.images.first)
        try FileManager.default.removeItem(atPath: image)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", first.commandLine]
        p.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        while p.isRunning, clock.now < deadline {
            try await Task.sleep(for: .seconds(1))
        }
        #expect(p.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: image), "コマンドの再実行で \(image) ができる")
        print("output: \(out.path)")
    }
}
