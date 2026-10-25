import Foundation
import Synchronization
import Testing
@testable import CodexImageFactory

/// 本物の ProcessCodexRunner + JobExecutor + JobQueue を、ダミーの codex スクリプトでつないだ結合テスト。
/// 受け入れ条件（5 件を並列数 3 で消化・各フォルダの中身・コマンドの再実行・中止・終了と復元）をなぞる。
@Suite("Integration", .serialized)
struct IntegrationTests {
    /// キューの通知を集める。
    final class EventLog: Sendable {
        private let events = Mutex<[QueueEvent]>([])
        private let maxRunning = Mutex(0)

        func start(_ queue: JobQueue) -> Task<Void, Never> {
            Task {
                for await event in queue.events {
                    if case .snapshot(let s) = event {
                        maxRunning.withLock { $0 = max($0, s.running.count) }
                    }
                    events.withLock { $0.append(event) }
                }
            }
        }

        var finished: [JobRecord] {
            events.withLock { list in
                list.compactMap { if case .finished(let r) = $0 { return r } else { return nil } }
            }
        }

        var drainedCount: Int {
            events.withLock { list in list.filter { if case .drained = $0 { true } else { false } }.count }
        }

        var rateLimitedCount: Int {
            events.withLock { list in list.filter { if case .rateLimited = $0 { true } else { false } }.count }
        }

        var lastSnapshot: QueueSnapshot? {
            events.withLock { list in
                list.reversed().lazy.compactMap { if case .snapshot(let s) = $0 { return s } else { return nil } }.first
            }
        }

        var peakRunning: Int { maxRunning.withLock { $0 } }
    }

    struct Fixture {
        let root: QTempDir
        let outputDir: URL
        let codexHome: URL
        let codex: URL
        let settings: AppSettings
        let executor: JobExecutor

        init(behavior: ProcDummyCodex.Behavior, concurrency: Int = 3, timeoutSeconds: Int = 600) throws {
            root = try QTempDir()
            outputDir = root.sub("out")
            codexHome = root.sub("codex-home")
            try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
            let bin = root.sub("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            codex = try ProcDummyCodex.make(in: bin, behavior: behavior)
            settings = qSettings(outputDirectory: outputDir, codexPath: codex.path, concurrency: concurrency, timeoutSeconds: timeoutSeconds)
            let home = codexHome
            executor = JobExecutor(
                runner: ProcessCodexRunner(killGracePeriod: 1),
                codexHome: home,
                environment: {
                    ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CODEX_HOME": home.path]
                }
            )
        }
    }

    @Test func fiveJobsWithConcurrencyThreeEachGetTheirOwnFolder() async throws {
        let f = try Fixture(behavior: .slow(0.6), concurrency: 3)
        defer { f.root.remove() }
        let store = QueueStore(fileURL: f.root.url.appendingPathComponent("queue.json"))
        let queue = JobQueue(executor: f.executor, store: store, settings: f.settings)
        let log = EventLog()
        let consumer = log.start(queue)
        defer { consumer.cancel() }

        let template = f.settings.instructionTemplate
        let jobs = JobFactory.batch(
            from: JobDraft(prompt: "猫\n\n犬\n\n鳥\n\n魚\n\n馬", slug: "pet", count: 2),
            preset: "水彩画風",
            template: template,
            now: Date()
        )
        #expect(jobs.count == 5)
        await queue.enqueue(jobs)

        let allDone = await qWaitUntil(timeout: .seconds(30)) { log.finished.count == 5 }
        #expect(allDone)
        #expect(log.peakRunning == 3)
        #expect(await qWaitUntil(timeout: .seconds(5)) { log.drainedCount == 1 })

        let finished = log.finished
        #expect(Set(finished.map(\.id)) == Set(jobs.map(\.id)))
        #expect(Set(finished.map(\.outputDir)).count == 5, "ジョブごとに別フォルダ")
        for record in finished {
            #expect(record.status == .done, "\(record.slug): \(record.errorSummary ?? "")")
            let folder = URL(fileURLWithPath: record.outputDir)
            #expect(folder.deletingLastPathComponent().standardizedFileURL.path == f.outputDir.standardizedFileURL.path)
            for name in ["run.json", "prompt.txt", "stdout.jsonl", "stderr.log", "last-message.md"] {
                #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "\(name) in \(folder.lastPathComponent)")
            }
            #expect(record.images.map { ($0 as NSString).lastPathComponent } == ["\(record.slug)-01.png", "\(record.slug)-02.png"])
            #expect(record.images.allSatisfy { FileManager.default.fileExists(atPath: $0) })

            let saved = try RunFolder.readRecord(from: folder)
            #expect(saved.id == record.id)
            #expect(saved.status == .done)
            #expect(saved.exitCode == 0)
            #expect(saved.command.first == f.codex.path)
            #expect(saved.fullPrompt.hasPrefix("水彩画風\n\n"))
            let prompt = try String(contentsOf: folder.appendingPathComponent("prompt.txt"), encoding: .utf8)
            #expect(prompt == saved.fullPrompt)
            let stdout = try String(contentsOf: folder.appendingPathComponent("stdout.jsonl"), encoding: .utf8)
            #expect(stdout.contains("\"thread.started\""))
            #expect(saved.codexThreadId != nil)
        }
        #expect(store.load().isEmpty, "全部終わったら待機中は空")
    }

    @Test func copiedCommandLineRunsAsIsInAShell() async throws {
        let f = try Fixture(behavior: .success)
        defer { f.root.remove() }
        let job = try #require(JobFactory.single(
            from: JobDraft(prompt: "it's a \"quoted\" $HOME `cat`\n二行目", slug: "my slug"),
            preset: "",
            template: f.settings.instructionTemplate,
            now: Date()
        ))
        let record = await f.executor.execute(job, settings: f.settings) { _ in }
        #expect(record.status == .done)
        let image = try #require(record.images.first)
        try FileManager.default.removeItem(atPath: image)

        // 履歴の「コマンドをコピー」と同じ文字列を、そのまま zsh に渡す。
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-f", "-c", record.commandLine]
        p.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: image), "コマンドの再実行で同じ画像ができる")
    }

    @Test func cancellingARunningJobStopsTheProcess() async throws {
        let f = try Fixture(behavior: .slow(30), concurrency: 1)
        defer { f.root.remove() }
        let queue = JobQueue(executor: f.executor, store: nil, settings: f.settings)
        let log = EventLog()
        let consumer = log.start(queue)
        defer { consumer.cancel() }

        let job = qMakeJob(slug: "long")
        await queue.enqueue([job])
        #expect(await qWaitUntil(timeout: .seconds(10)) { log.lastSnapshot?.running.first?.outputDir.isEmpty == false })
        let clock = ContinuousClock()
        let started = clock.now
        await queue.cancel(job.id)
        #expect(await qWaitUntil(timeout: .seconds(10)) { log.finished.count == 1 })
        #expect(clock.now - started < .seconds(6))
        let record = try #require(log.finished.first)
        #expect(record.status == .cancelled)
        let saved = try RunFolder.readRecord(from: URL(fileURLWithPath: record.outputDir))
        #expect(saved.status == .cancelled)
    }

    @Test func quitAndRelaunchKeepsWaitingJobsPaused() async throws {
        let f = try Fixture(behavior: .slow(30), concurrency: 1)
        defer { f.root.remove() }
        let storeURL = f.root.url.appendingPathComponent("queue.json")
        let store = QueueStore(fileURL: storeURL)
        let queue = JobQueue(executor: f.executor, store: store, settings: f.settings)
        let log = EventLog()
        let consumer = log.start(queue)

        let jobs = (1...4).map { qMakeJob(slug: "job\($0)", createdAt: Date().addingTimeInterval(Double($0))) }
        await queue.enqueue(jobs)
        #expect(await qWaitUntil(timeout: .seconds(10)) { log.lastSnapshot?.running.count == 1 })
        await queue.shutdown(timeout: 5)
        consumer.cancel()

        let saved = store.load()
        #expect(saved.count == 4, "実行中だった 1 件（作り直し）+ 待機中 3 件")
        #expect(saved.map(\.slug) == ["job1", "job2", "job3", "job4"])
        #expect(saved.allSatisfy { $0.status == .queued })

        // 再起動: 保存されたジョブを戻すと一時停止状態。
        let relaunched = JobQueue(executor: f.executor, store: store, settings: f.settings)
        await relaunched.restore(store.load())
        let snap = await relaunched.snapshot()
        #expect(snap.isPaused)
        #expect(snap.queued.count == 4)
        #expect(snap.running.isEmpty)
    }

    @Test func rateLimitPausesTheQueue() async throws {
        let f = try Fixture(behavior: .rateLimited, concurrency: 1)
        defer { f.root.remove() }
        let queue = JobQueue(executor: f.executor, store: nil, settings: f.settings)
        let log = EventLog()
        let consumer = log.start(queue)
        defer { consumer.cancel() }

        await queue.enqueue([qMakeJob(slug: "a"), qMakeJob(slug: "b")])
        #expect(await qWaitUntil(timeout: .seconds(10)) { log.finished.count == 1 })
        #expect(await qWaitUntil(timeout: .seconds(5)) { log.rateLimitedCount >= 1 })
        let snap = await queue.snapshot()
        #expect(snap.isPaused)
        #expect(snap.queued.map(\.slug) == ["b"], "自動リトライはせず、残りは待機のまま")
        #expect(log.finished.first?.status == .failed)
        #expect(log.drainedCount == 0)
    }

    @Test func imagesOnlyInCodexHomeAreCopiedIn() async throws {
        let f = try Fixture(behavior: .generatedOnly)
        defer { f.root.remove() }
        let job = qMakeJob(slug: "fallback", count: 1)
        let record = await f.executor.execute(job, settings: f.settings) { _ in }
        #expect(record.status == .done, "\(record.errorSummary ?? "")")
        #expect(record.images.map { ($0 as NSString).lastPathComponent } == ["fallback-01.png"])
    }
}
