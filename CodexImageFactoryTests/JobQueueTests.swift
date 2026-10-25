import Foundation
import Synchronization
import Testing
@testable import CodexImageFactory

// MARK: - ダミーの executor

/// JobExecuting の代わり。同時実行数と開始順を記録する。
///
/// - `hold == true` のジョブは `release` されるまで終わらない（キャンセルされたら cancelled を返す）。
/// - `hold == false` なら `delay` だけ待って done を返す。
final class QMockExecutor: JobExecuting {
    struct State {
        var current = 0
        var maxConcurrent = 0
        var startedSlugs: [String] = []
        var finishedSlugs: [String] = []
        var released: Set<String> = []
        var releaseAll = false
        var settingsSeen: [AppSettings] = []
    }

    let state = Mutex(State())
    let hold: Bool
    let delay: Duration
    let linesPerJob: Int
    let rateLimitSlugs: Set<String>
    /// true ならキャンセルを無視して release まで待つ（止まらないジョブ）。
    let ignoresCancel: Bool
    /// このスラッグのジョブだけキャンセルを無視して release まで待ち、release されたら done を返す。
    let ignoresCancelSlugs: Set<String>

    init(
        hold: Bool = false,
        delay: Duration = .milliseconds(20),
        linesPerJob: Int = 0,
        rateLimitSlugs: Set<String> = [],
        ignoresCancel: Bool = false,
        ignoresCancelSlugs: Set<String> = []
    ) {
        self.hold = hold
        self.delay = delay
        self.linesPerJob = linesPerJob
        self.rateLimitSlugs = rateLimitSlugs
        self.ignoresCancel = ignoresCancel
        self.ignoresCancelSlugs = ignoresCancelSlugs
    }

    var current: Int { state.withLock { $0.current } }
    var maxConcurrent: Int { state.withLock { $0.maxConcurrent } }
    var startedSlugs: [String] { state.withLock { $0.startedSlugs } }
    var finishedSlugs: [String] { state.withLock { $0.finishedSlugs } }

    func release(_ slug: String) {
        _ = state.withLock { $0.released.insert(slug) }
    }

    func releaseAll() {
        state.withLock { $0.releaseAll = true }
    }

    func execute(
        _ job: JobRecord,
        settings: AppSettings,
        onEvent: @escaping @Sendable (JobEvent) -> Void
    ) async -> JobRecord {
        state.withLock { s in
            s.current += 1
            s.maxConcurrent = max(s.maxConcurrent, s.current)
            s.startedSlugs.append(job.slug)
            s.settingsSeen.append(settings)
        }
        var r = job
        r.status = .running
        r.startedAt = Date()
        r.outputDir = "/tmp/qmock/\(job.slug)"
        r.commandLine = "codex exec \(job.slug)"
        onEvent(.started(r))
        for i in 0..<linesPerJob {
            onEvent(.line(i.isMultiple(of: 3) ? .stderr : .stdout, "\(job.slug) line \(i)"))
        }
        if rateLimitSlugs.contains(job.slug) {
            onEvent(.line(.stderr, "Error: 429 Too Many Requests"))
            onEvent(.rateLimited("Error: 429 Too Many Requests"))
        }
        let cancelled = await wait(for: job.slug)
        state.withLock { s in
            s.current -= 1
            s.finishedSlugs.append(job.slug)
        }
        r.finishedAt = Date()
        if cancelled {
            r.status = .cancelled
            r.errorSummary = "中止しました"
        } else {
            r.status = .done
            r.images = ["/tmp/qmock/\(job.slug)/\(job.slug)-01.png"]
            r.exitCode = 0
        }
        return r
    }

    /// 終わってよくなるまで待つ。キャンセルされたら true。
    private func wait(for slug: String) async -> Bool {
        guard hold else {
            do {
                try await Task.sleep(for: delay)
                return false
            } catch {
                return true
            }
        }
        let ignores = ignoresCancel || ignoresCancelSlugs.contains(slug)
        while true {
            if !ignores, Task.isCancelled { return true }
            if state.withLock({ $0.releaseAll || $0.released.contains(slug) }) { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

// MARK: - 出来事の記録

/// `queue.events` を読み続けて記録する。
final class QQueueRecorder: Sendable {
    let log = QLog<QueueEvent>()
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(_ queue: JobQueue) {
        let log = log
        let t = Task {
            for await event in queue.events {
                log.append(event)
            }
        }
        task.withLock { $0 = t }
    }

    func stop() {
        task.withLock { $0?.cancel() }
    }

    var finished: [JobRecord] {
        log.all.compactMap { event in
            if case .finished(let r) = event { return r }
            return nil
        }
    }

    var drainedCount: Int {
        log.all.filter { event in
            if case .drained = event { return true }
            return false
        }.count
    }

    var rateLimited: [(UUID, String)] {
        log.all.compactMap { event in
            if case .rateLimited(let id, let message) = event { return (id, message) }
            return nil
        }
    }

    var lastSnapshot: QueueSnapshot? {
        log.all.compactMap { event in
            if case .snapshot(let s) = event { return s }
            return nil
        }.last
    }

    func lines(for id: UUID) -> [String] {
        log.all.compactMap { event in
            if case .line(let jobID, _, let text) = event, jobID == id { return text }
            return nil
        }
    }

    func finishedSlugs() -> [String] {
        finished.map(\.slug)
    }

    /// キューが起動した順。起動のたびに写しが流れ、実行中は開始順に並ぶので、初めて現れた順がそのまま起動順になる。
    /// （同時に起動したジョブが executor に入る順は決まらないので、こちらで比べる）
    func startOrder() -> [String] {
        var seen = Set<UUID>()
        var order: [String] = []
        for event in log.all {
            guard case .snapshot(let s) = event else { continue }
            for r in s.running where seen.insert(r.id).inserted {
                order.append(r.slug)
            }
        }
        return order
    }
}

/// テスト 1 件分の道具一式。
private struct QQueueFixture {
    let tmp: QTempDir
    let store: QueueStore
    let executor: QMockExecutor
    let queue: JobQueue
    let recorder: QQueueRecorder

    init(executor: QMockExecutor, concurrency: Int, withStore: Bool = true) throws {
        tmp = try QTempDir()
        store = QueueStore(fileURL: tmp.url.appendingPathComponent("support/queue.json"))
        self.executor = executor
        queue = JobQueue(
            executor: executor,
            store: withStore ? store : nil,
            settings: qSettings(outputDirectory: tmp.sub("out"), concurrency: concurrency)
        )
        recorder = QQueueRecorder(queue)
    }

    func tearDown() {
        executor.releaseAll()
        recorder.stop()
        tmp.remove()
    }

    func settings(concurrency: Int) -> AppSettings {
        qSettings(outputDirectory: tmp.sub("out"), concurrency: concurrency)
    }
}

private func qJobs(_ slugs: [String]) -> [JobRecord] {
    let base = Date()
    return slugs.enumerated().map { i, slug in qMakeJob(slug: slug, createdAt: base.addingTimeInterval(Double(i) * 0.001)) }
}

// MARK: - JobQueue

@Suite("JobQueue")
struct JobQueueTests {
    @Test func runsFiveJobsWithConcurrencyThree() async throws {
        let f = try QQueueFixture(executor: QMockExecutor(hold: true), concurrency: 3)
        defer { f.tearDown() }
        let jobs = qJobs(["j1", "j2", "j3", "j4", "j5"])
        await f.queue.enqueue(jobs)

        #expect(await qWaitUntil { f.executor.current == 3 })
        // 少し待っても 4 本目は始まらない。
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.executor.startedSlugs.sorted() == ["j1", "j2", "j3"])
        #expect(await qWaitUntil { f.recorder.startOrder() == ["j1", "j2", "j3"] })
        let snap = await f.queue.snapshot()
        #expect(snap.running.map(\.slug) == ["j1", "j2", "j3"])
        #expect(snap.running.allSatisfy { $0.status == .running && $0.startedAt != nil })
        #expect(snap.queued.map(\.slug) == ["j4", "j5"])
        #expect(snap.concurrency == 3)

        f.executor.release("j2")
        #expect(await qWaitUntil { f.executor.startedSlugs.count == 4 })
        #expect(f.executor.startedSlugs.last == "j4")
        f.executor.releaseAll()

        #expect(await qWaitUntil { f.recorder.finished.count == 5 })
        #expect(f.executor.maxConcurrent == 3)
        #expect(f.executor.startedSlugs.last == "j5")
        #expect(f.recorder.startOrder() == ["j1", "j2", "j3", "j4", "j5"])
        #expect(Set(f.recorder.finished.map(\.id)) == Set(jobs.map(\.id)))
        #expect(f.recorder.finished.allSatisfy { $0.status == .done })
        let end = await f.queue.snapshot()
        #expect(end.queued.isEmpty && end.running.isEmpty)
    }

    @Test func concurrencyOneIsSequential() async throws {
        let f = try QQueueFixture(executor: QMockExecutor(delay: .milliseconds(15)), concurrency: 1)
        defer { f.tearDown() }
        await f.queue.enqueue(qJobs(["a", "b", "c", "d"]))
        #expect(await qWaitUntil { f.recorder.finished.count == 4 })
        #expect(f.executor.maxConcurrent == 1)
        #expect(f.executor.startedSlugs == ["a", "b", "c", "d"])
        #expect(f.recorder.finishedSlugs() == ["a", "b", "c", "d"])
    }

    @Test func pauseStopsNewStartsAndResumeContinues() async throws {
        let f = try QQueueFixture(executor: QMockExecutor(hold: true), concurrency: 1)
        defer { f.tearDown() }
        await f.queue.enqueue(qJobs(["a", "b", "c"]))
        #expect(await qWaitUntil { f.executor.startedSlugs == ["a"] })
        await f.queue.pause()
        #expect(await f.queue.snapshot().isPaused)

        // 実行中のジョブは止めずに走らせる。
        f.executor.release("a")
        #expect(await qWaitUntil { f.recorder.finishedSlugs() == ["a"] })
        #expect(f.recorder.finished.first?.status == .done)
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.executor.startedSlugs == ["a"])
        let paused = await f.queue.snapshot()
        #expect(paused.queued.map(\.slug) == ["b", "c"])
        #expect(paused.running.isEmpty)
        #expect(f.recorder.drainedCount == 0, "待機中が残っているあいだは drained を出さない")

        await f.queue.resume()
        #expect(await qWaitUntil { f.executor.startedSlugs == ["a", "b"] })
        #expect(await f.queue.snapshot().isPaused == false)
        f.executor.releaseAll()
        #expect(await qWaitUntil { f.recorder.finished.count == 3 })
        #expect(await qWaitUntil { f.recorder.drainedCount == 1 })
    }

    @Test func editingQueuedJobs() async throws {
        let f = try QQueueFixture(executor: QMockExecutor(hold: true), concurrency: 1)
        defer { f.tearDown() }
        let jobs = qJobs(["run", "a", "b", "c"])
        await f.queue.enqueue(jobs)
        #expect(await qWaitUntil { f.executor.startedSlugs == ["run"] })
        let (run, a, b, c) = (jobs[0], jobs[1], jobs[2], jobs[3])
        func order() async -> [String] { await f.queue.snapshot().queued.map(\.slug) }

        #expect(await order() == ["a", "b", "c"])
        await f.queue.moveUp(c.id)
        #expect(await order() == ["a", "c", "b"])
        await f.queue.moveDown(a.id)
        #expect(await order() == ["c", "a", "b"])
        await f.queue.moveUp(c.id) // 先頭なので何もしない
        await f.queue.moveDown(b.id) // 末尾なので何もしない
        await f.queue.moveUp(run.id) // 実行中は動かせない
        await f.queue.moveUp(UUID())
        #expect(await order() == ["c", "a", "b"])

        var edited = b
        edited.prompt = "犬のイラスト"
        edited.slug = "b2"
        edited.status = .failed
        #expect(await f.queue.update(edited))
        let afterUpdate = await f.queue.snapshot().queued
        #expect(afterUpdate.map(\.slug) == ["c", "a", "b2"])
        #expect(afterUpdate[2].prompt == "犬のイラスト")
        #expect(afterUpdate[2].status == .queued)
        #expect(await f.queue.update(qMakeJob(slug: "unknown")) == false)
        var runningEdit = run
        runningEdit.prompt = "変更"
        #expect(await f.queue.update(runningEdit) == false)

        #expect(await f.queue.remove(a.id))
        #expect(await order() == ["c", "b2"])
        #expect(await f.queue.remove(a.id) == false)
        #expect(await f.queue.remove(run.id) == false)
        #expect(f.store.load().map(\.slug) == ["c", "b2"])

        // 並べ替えた順に実行される。
        f.executor.releaseAll()
        #expect(await qWaitUntil { f.recorder.finished.count == 3 })
        #expect(f.executor.startedSlugs == ["run", "c", "b2"])
    }

    @Test func cancelRunningJob() async throws {
        let f = try QQueueFixture(executor: QMockExecutor(hold: true), concurrency: 1)
        defer { f.tearDown() }
        let jobs = qJobs(["a", "b"])
        await f.queue.enqueue(jobs)
        #expect(await qWaitUntil { f.executor.startedSlugs == ["a"] })
        await f.queue.cancel(UUID()) // 知らない id は無視
        await f.queue.cancel(jobs[1].id) // 待機中は対象外
        await f.queue.cancel(jobs[0].id)
        #expect(await qWaitUntil { f.recorder.finished.count == 1 })
        let first = try #require(f.recorder.finished.first)
        #expect(first.id == jobs[0].id)
        #expect(first.status == .cancelled)
        // 次のジョブが始まる。
        #expect(await qWaitUntil { f.executor.startedSlugs == ["a", "b"] })
        f.executor.releaseAll()
        #expect(await qWaitUntil { f.recorder.finished.count == 2 })
        #expect(f.recorder.finished[1].status == .done)
    }

    @Test func rateLimitAutoPauses() async throws {
        let f = try QQueueFixture(executor: QMockExecutor(delay: .milliseconds(30), rateLimitSlugs: ["rl"]), concurrency: 1)
        defer { f.tearDown() }
        let jobs = qJobs(["rl", "next"])
        await f.queue.enqueue(jobs)
        #expect(await qWaitUntil { f.recorder.finished.count == 1 })
        #expect(await qWaitUntil { f.recorder.rateLimited.count == 1 })
        let event = try #require(f.recorder.rateLimited.first)
        #expect(event.0 == jobs[0].id)
        #expect(event.1.contains("429"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.executor.startedSlugs == ["rl"])
        let snap = await f.queue.snapshot()
        #expect(snap.isPaused)
        #expect(snap.queued.map(\.slug) == ["next"])
        #expect(f.recorder.drainedCount == 0)

        // 再開したら続きが走り、再び止まることはない。
        await f.queue.resume()
        #expect(await qWaitUntil { f.recorder.finished.count == 2 })
        #expect(await f.queue.snapshot().isPaused == false)
        #expect(f.recorder.rateLimited.count == 1)
    }

    @Test func rateLimitPausesBeforeNextStartEvenWhenJobEndsImmediately() async throws {
        // 検出した直後にジョブが終わり、一時停止の Task より先に finish が actor に着いても、次のジョブは起動しない。
        // 一時停止の Task を遅らせて、finish が必ず先に着くようにする。
        let f = try QQueueFixture(executor: QMockExecutor(delay: .zero, rateLimitSlugs: ["rl"]), concurrency: 1)
        defer { f.tearDown() }
        let handoff = Duration.seconds(2)
        await f.queue.setRateLimitHandoffDelayForTesting(handoff)
        let clock = ContinuousClock()
        let started = clock.now
        await f.queue.enqueue(qJobs(["rl", "next", "last"]))
        #expect(await qWaitUntil { f.recorder.finished.count >= 1 })
        #expect(await qWaitUntil { f.recorder.rateLimited.count == 1 })
        // 遅らせた一時停止がまだ届いていないうちに、もう止まっている。
        let snap = await f.queue.snapshot()
        #expect(clock.now - started < handoff, "遅らせた一時停止が届く前に確かめる")
        #expect(snap.isPaused)
        #expect(snap.queued.map(\.slug) == ["next", "last"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.executor.startedSlugs == ["rl"])
        #expect(f.recorder.drainedCount == 0)
    }

    @Test func drainedIsEmittedOncePerDrain() async throws {
        let f = try QQueueFixture(executor: QMockExecutor(delay: .milliseconds(10)), concurrency: 2)
        defer { f.tearDown() }
        await f.queue.enqueue(qJobs(["a", "b", "c"]))
        #expect(await qWaitUntil { f.recorder.finished.count == 3 })
        #expect(await qWaitUntil { f.recorder.drainedCount == 1 })
        try await Task.sleep(for: .milliseconds(80))
        #expect(f.recorder.drainedCount == 1)
        // drained は最後の finished より後。
        let kinds = f.recorder.log.all.map { event -> String in
            switch event {
            case .finished: "finished"
            case .drained: "drained"
            default: "other"
            }
        }.filter { $0 != "other" }
        #expect(kinds == ["finished", "finished", "finished", "drained"])

        await f.queue.enqueue(qJobs(["d"]))
        #expect(await qWaitUntil { f.recorder.finished.count == 4 })
        #expect(await qWaitUntil { f.recorder.drainedCount == 2 })
    }

    @Test func noDrainedWithoutProcessing() async throws {
        let f = try QQueueFixture(executor: QMockExecutor(), concurrency: 1)
        defer { f.tearDown() }
        await f.queue.pause()
        let jobs = qJobs(["a"])
        await f.queue.enqueue(jobs)
        await f.queue.remove(jobs[0].id)
        await f.queue.resume()
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.recorder.drainedCount == 0)
    }

    @Test func persistsQueuedJobsOnEveryMutation() async throws {
        let f = try QQueueFixture(executor: QMockExecutor(hold: true), concurrency: 1)
        defer { f.tearDown() }
        func saved() -> [String] { f.store.load().map(\.slug) }

        await f.queue.pause()
        let jobs = qJobs(["a", "b", "c"])
        await f.queue.enqueue(jobs)
        #expect(saved() == ["a", "b", "c"])
        #expect(f.store.load().allSatisfy { $0.status == .queued })
        await f.queue.moveUp(jobs[2].id)
        #expect(saved() == ["a", "c", "b"])
        await f.queue.moveDown(jobs[0].id)
        #expect(saved() == ["c", "a", "b"])
        var edited = jobs[1]
        edited.slug = "b-edited"
        await f.queue.update(edited)
        #expect(saved() == ["c", "a", "b-edited"])
        await f.queue.remove(jobs[0].id)
        #expect(saved() == ["c", "b-edited"])

        // 起動して待機中から抜けたら、それも保存する。
        await f.queue.resume()
        #expect(await qWaitUntil { f.executor.startedSlugs == ["c"] })
        #expect(saved() == ["b-edited"])
        f.executor.releaseAll()
        #expect(await qWaitUntil { f.recorder.finished.count == 2 })
        #expect(saved() == [])
    }

    @Test func restorePutsJobsAtFrontAndPauses() async throws {
        let f = try QQueueFixture(executor: QMockExecutor(hold: true), concurrency: 2)
        defer { f.tearDown() }
        await f.queue.pause()
        await f.queue.enqueue(qJobs(["x"]))
        await f.queue.resume()
        #expect(await qWaitUntil { f.executor.startedSlugs == ["x"] })
        await f.queue.pause()
        await f.queue.enqueue(qJobs(["y"]))

        var stale = qMakeJob(slug: "r1")
        stale.status = .running
        stale.outputDir = "/old"
        let restored = [stale, qMakeJob(slug: "r2")]
        await f.queue.resume()
        // resume で y が走り出す前に restore するため、並列数の枠を埋めておく。
        #expect(await qWaitUntil { f.executor.startedSlugs == ["x", "y"] })
        await f.queue.restore(restored)
        let snap = await f.queue.snapshot()
        #expect(snap.isPaused)
        #expect(snap.queued.map(\.slug) == ["r1", "r2"])
        #expect(snap.queued.allSatisfy { $0.status == .queued && $0.outputDir.isEmpty })
        #expect(f.store.load().map(\.id) == restored.map(\.id))

        // 先頭側に入る（既存の待機中より前）。
        await f.queue.enqueue(qJobs(["z"]))
        await f.queue.restore([qMakeJob(slug: "r0")])
        #expect(await f.queue.snapshot().queued.map(\.slug) == ["r0", "r1", "r2", "z"])
        // 同じ id は二重に入れない。
        await f.queue.restore(restored)
        #expect(await f.queue.snapshot().queued.count == 4)
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.executor.startedSlugs == ["x", "y"])

        // 再開すると先頭から走る。
        f.executor.releaseAll()
        await f.queue.updateSettings(f.settings(concurrency: 1))
        await f.queue.resume()
        #expect(await qWaitUntil { f.recorder.finished.count == 6 })
        #expect(f.executor.startedSlugs == ["x", "y", "r0", "r1", "r2", "z"])
        #expect(f.recorder.startOrder() == ["x", "y", "r0", "r1", "r2", "z"])
    }

    @Test func restoringNothingDoesNotPause() async throws {
        let f = try QQueueFixture(executor: QMockExecutor(delay: .zero), concurrency: 1)
        defer { f.tearDown() }
        await f.queue.restore([])
        #expect(await f.queue.snapshot().isPaused == false)
        await f.queue.enqueue(qJobs(["a"]))
        #expect(await qWaitUntil { f.recorder.finished.count == 1 })
    }

    @Test func shutdownRequeuesRunningJobsAtFront() async throws {
        let f = try QQueueFixture(executor: QMockExecutor(hold: true), concurrency: 2)
        defer { f.tearDown() }
        let jobs = qJobs(["a", "b", "c"])
        await f.queue.enqueue(jobs)
        #expect(await qWaitUntil { f.executor.current == 2 })

        await f.queue.shutdown(timeout: 5)
        let snap = await f.queue.snapshot()
        #expect(snap.running.isEmpty)
        #expect(snap.isPaused)
        #expect(snap.queued.map(\.slug) == ["a", "b", "c"])
        #expect(snap.queued[0].id != jobs[0].id)
        #expect(snap.queued[1].id != jobs[1].id)
        #expect(snap.queued[2].id == jobs[2].id)
        #expect(snap.queued.allSatisfy { $0.status == .queued && $0.startedAt == nil })
        #expect(f.store.load().map(\.slug) == ["a", "b", "c"])
        #expect(await qWaitUntil { Set(f.recorder.finished.map(\.id)) == Set([jobs[0].id, jobs[1].id]) })
        #expect(f.recorder.finished.allSatisfy { $0.status == .cancelled })
        #expect(f.recorder.drainedCount == 0)

        // 2 回目は何も変えない。終了処理のあとは再開しても起動しない。
        await f.queue.shutdown(timeout: 5)
        #expect(await f.queue.snapshot().queued.count == 3)
        await f.queue.resume()
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.executor.startedSlugs.sorted() == ["a", "b"])
    }

    @Test func shutdownGivesUpAfterTimeout() async throws {
        let f = try QQueueFixture(executor: QMockExecutor(hold: true, ignoresCancel: true), concurrency: 1)
        defer { f.tearDown() }
        await f.queue.enqueue(qJobs(["stuck"]))
        #expect(await qWaitUntil { f.executor.current == 1 })
        let clock = ContinuousClock()
        let started = clock.now
        await f.queue.shutdown(timeout: 0.2)
        #expect(clock.now - started < .seconds(3))
        let snap = await f.queue.snapshot()
        #expect(snap.queued.map(\.slug) == ["stuck"])
        #expect(f.store.load().map(\.slug) == ["stuck"])
    }

    @Test func shutdownWithNothingRunningPersists() async throws {
        let f = try QQueueFixture(executor: QMockExecutor(), concurrency: 1)
        defer { f.tearDown() }
        await f.queue.pause()
        await f.queue.enqueue(qJobs(["a", "b"]))
        try? FileManager.default.removeItem(at: f.store.fileURL)
        await f.queue.shutdown()
        #expect(f.store.load().map(\.slug) == ["a", "b"])
    }

    @Test func concurrentShutdownCallsWaitForTheFirst() async throws {
        // "slow" は中止を無視し、少したってから終わる。2 回目の呼び出しは、1 回目の戻し・保存が終わるまで戻らない。
        let f = try QQueueFixture(executor: QMockExecutor(hold: true, ignoresCancelSlugs: ["slow"]), concurrency: 2)
        defer { f.tearDown() }
        await f.queue.enqueue(qJobs(["slow", "quick"]))
        #expect(await qWaitUntil { f.executor.current == 2 })
        let queue = f.queue
        let first = Task { await queue.shutdown(timeout: 5) }
        // 1 回目が始まった（quick は中止された）。
        #expect(await qWaitUntil { f.recorder.finished.contains { $0.slug == "quick" } })
        let releaseAfter = Duration.milliseconds(300)
        let executor = f.executor
        let releaser = Task {
            try? await Task.sleep(for: releaseAfter)
            executor.release("slow")
        }
        let clock = ContinuousClock()
        let calledAt = clock.now
        await queue.shutdown(timeout: 5)
        let waited = clock.now - calledAt

        // 戻った時点で、1 回目の処理（slow の終了待ち → 戻し → 保存）は終わっている。
        #expect(f.executor.finishedSlugs.contains("slow"))
        let snap = await queue.snapshot()
        #expect(snap.running.isEmpty)
        #expect(snap.queued.map(\.slug) == ["quick"])
        #expect(f.store.load().map(\.slug) == ["quick"])
        #expect(waited >= .milliseconds(200))
        await first.value
        await releaser.value
    }

    @Test func shutdownDoesNotRequeueJobThatFinishedDone() async throws {
        // 終了処理の待ち時間内に done で終わったジョブは戻さない（もう一度生成しない）。中止されたものは戻す。
        let f = try QQueueFixture(executor: QMockExecutor(hold: true, ignoresCancelSlugs: ["finishes"]), concurrency: 2)
        defer { f.tearDown() }
        let jobs = qJobs(["finishes", "stopped", "waiting"])
        await f.queue.enqueue(jobs)
        #expect(await qWaitUntil { f.executor.current == 2 })
        let queue = f.queue
        let shutdown = Task { await queue.shutdown(timeout: 5) }
        #expect(await qWaitUntil { f.recorder.finished.contains { $0.slug == "stopped" } })
        // 終了処理の途中で、中止を無視していたジョブが完了する。
        f.executor.release("finishes")
        await shutdown.value

        let finished = f.recorder.finished
        #expect(finished.first { $0.id == jobs[0].id }?.status == .done)
        #expect(finished.first { $0.id == jobs[1].id }?.status == .cancelled)
        let snap = await f.queue.snapshot()
        #expect(snap.queued.map(\.slug) == ["stopped", "waiting"])
        #expect(snap.queued[0].id != jobs[1].id, "中止したものは新しいジョブとして戻す")
        #expect(snap.queued[1].id == jobs[2].id)
        #expect(!snap.queued.contains { $0.slug == "finishes" })
        #expect(f.store.load().map(\.slug) == ["stopped", "waiting"])
        // 再起動後も二重に生成しない。
        #expect(f.executor.startedSlugs.sorted() == ["finishes", "stopped"])
    }

    @Test func raisingConcurrencyStartsMoreImmediately() async throws {
        let f = try QQueueFixture(executor: QMockExecutor(hold: true), concurrency: 1)
        defer { f.tearDown() }
        await f.queue.enqueue(qJobs(["j1", "j2", "j3", "j4"]))
        #expect(await qWaitUntil { f.executor.current == 1 })
        await f.queue.updateSettings(f.settings(concurrency: 3))
        #expect(await qWaitUntil { f.executor.current == 3 })
        #expect(f.executor.startedSlugs.sorted() == ["j1", "j2", "j3"])
        #expect(await qWaitUntil { f.recorder.startOrder() == ["j1", "j2", "j3"] })
        #expect(await f.queue.snapshot().concurrency == 3)

        // 減らしても実行中は止めない。上限を下回るまで新しく起動しない。
        await f.queue.updateSettings(f.settings(concurrency: 1))
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.executor.current == 3)
        #expect(f.recorder.finished.isEmpty)
        f.executor.release("j1")
        f.executor.release("j2")
        #expect(await qWaitUntil { f.recorder.finished.count == 2 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.executor.startedSlugs.count == 3)
        f.executor.release("j3")
        #expect(await qWaitUntil { f.executor.startedSlugs.count == 4 })
        #expect(f.executor.startedSlugs.last == "j4")
        f.executor.releaseAll()
        #expect(await qWaitUntil { f.recorder.finished.count == 4 })
    }

    @Test func settingsAreNormalizedAndPassedToExecutor() async throws {
        let f = try QQueueFixture(executor: QMockExecutor(delay: .zero), concurrency: 99)
        defer { f.tearDown() }
        #expect(await f.queue.snapshot().concurrency == AppSettings.concurrencyRange.upperBound)
        var s = f.settings(concurrency: 0)
        s.timeoutSeconds = 1
        s.model = "m-test"
        await f.queue.updateSettings(s)
        #expect(await f.queue.snapshot().concurrency == 1)
        await f.queue.enqueue(qJobs(["a"]))
        #expect(await qWaitUntil { f.recorder.finished.count == 1 })
        let seen = try #require(f.executor.state.withLock { $0.settingsSeen.first })
        #expect(seen.model == "m-test")
        #expect(seen.timeoutSeconds == AppSettings.minimumTimeoutSeconds)
    }

    @Test func linesAreForwardedInOrder() async throws {
        let f = try QQueueFixture(executor: QMockExecutor(delay: .zero, linesPerJob: 300), concurrency: 2)
        defer { f.tearDown() }
        let jobs = qJobs(["a", "b"])
        await f.queue.enqueue(jobs)
        #expect(await qWaitUntil { f.recorder.finished.count == 2 })
        for job in jobs {
            #expect(f.recorder.lines(for: job.id) == (0..<300).map { "\(job.slug) line \($0)" })
        }
        // 行は finished より前に届く。
        let all = f.recorder.log.all
        let lastLine = try #require(all.lastIndex { if case .line(let id, _, _) = $0 { return id == jobs[0].id }; return false })
        let finished = try #require(all.firstIndex { if case .finished(let r) = $0 { return r.id == jobs[0].id }; return false })
        #expect(lastLine < finished)
    }

    @Test func startedEventUpdatesRunningRecord() async throws {
        let f = try QQueueFixture(executor: QMockExecutor(hold: true), concurrency: 1)
        defer { f.tearDown() }
        await f.queue.enqueue(qJobs(["a"]))
        #expect(await qWaitUntil { await f.queue.snapshot().running.first?.outputDir == "/tmp/qmock/a" })
        let running = try #require(await f.queue.snapshot().running.first)
        #expect(running.status == .running)
        #expect(running.commandLine == "codex exec a")
        #expect(await qWaitUntil { f.recorder.lastSnapshot?.running.first?.outputDir == "/tmp/qmock/a" })
    }

    @Test func enqueueNormalizesAndSkipsDuplicates() async throws {
        let f = try QQueueFixture(executor: QMockExecutor(), concurrency: 1, withStore: false)
        defer { f.tearDown() }
        await f.queue.pause()
        var job = qMakeJob(slug: "a")
        job.status = .failed
        job.errorSummary = "前回"
        job.images = ["/x.png"]
        await f.queue.enqueue([job, job])
        await f.queue.enqueue([job])
        let snap = await f.queue.snapshot()
        #expect(snap.queued.count == 1)
        #expect(snap.queued[0].status == .queued)
        #expect(snap.queued[0].errorSummary == nil)
        #expect(snap.queued[0].images.isEmpty)
        #expect(await qWaitUntil { f.recorder.lastSnapshot == snap })
    }

    @Test func neverExceedsConcurrencyUnderChurn() async throws {
        let f = try QQueueFixture(executor: QMockExecutor(delay: .milliseconds(3)), concurrency: 3)
        defer { f.tearDown() }
        let slugs = (1...30).map { "j\($0)" }
        await f.queue.enqueue(qJobs(slugs))
        // 途中で並列数を上下させる。
        await f.queue.updateSettings(f.settings(concurrency: 2))
        await f.queue.updateSettings(f.settings(concurrency: 3))
        #expect(await qWaitUntil { f.recorder.finished.count == 30 })
        #expect(f.executor.maxConcurrent <= 3)
        #expect(f.executor.startedSlugs.sorted() == slugs.sorted())
        #expect(f.recorder.startOrder() == slugs)
        #expect(await qWaitUntil { f.recorder.drainedCount == 1 })
    }
}

// MARK: - 本物の JobExecutor と組み合わせる

@Suite("JobQueue + JobExecutor")
struct JobQueueIntegrationTests {
    @Test func fivePromptsWithConcurrencyThreeLandInSeparateFolders() async throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.sub("out")
        let codexPath = try qMakeFakeCodex(in: tmp.url)
        // プロンプトに書かれたファイル名を作業ディレクトリに書く（本物の codex の代わり）。
        let runner = QMockRunner { invocation, onLine in
            onLine(.stdout, #"{"type":"thread.started","thread_id":"t-\#(UUID().uuidString)"}"#)
            try? await Task.sleep(for: .milliseconds(30))
            let prompt = invocation.arguments.last ?? ""
            let name = prompt.components(separatedBy: "`").first { $0.hasSuffix(".png") } ?? "unknown.png"
            try qPNGData().write(to: invocation.workingDirectory.appendingPathComponent(name))
            if let url = QMockRunner.lastMessageURL(invocation) {
                try Data("\(name)\n".utf8).write(to: url)
            }
            onLine(.stdout, #"{"type":"turn.completed"}"#)
            return ProcessOutcome(exitCode: 0)
        }
        let executor = JobExecutor(
            runner: runner,
            codexHome: tmp.sub("codex-home"),
            environment: { ["HOME": NSHomeDirectory()] }
        )
        let store = QueueStore(fileURL: tmp.url.appendingPathComponent("queue.json"))
        let queue = JobQueue(executor: executor, store: store, settings: qSettings(outputDirectory: out, codexPath: codexPath, concurrency: 3))
        let recorder = QQueueRecorder(queue)
        defer { recorder.stop() }

        let jobs = qJobs(["p1", "p2", "p3", "p4", "p5"])
        await queue.enqueue(jobs)
        #expect(await qWaitUntil { recorder.finished.count == 5 })
        #expect(await qWaitUntil { recorder.drainedCount == 1 })
        #expect(runner.maxConcurrent <= 3)

        let finished = recorder.finished
        #expect(finished.allSatisfy { $0.status == .done })
        #expect(Set(finished.map(\.outputDir)).count == 5)
        let fm = FileManager.default
        for record in finished {
            let folder = URL(fileURLWithPath: record.outputDir)
            #expect(record.images == [folder.appendingPathComponent("\(record.slug)-01.png").path])
            for name in [RunFolder.recordFileName, RunFolder.promptFileName, RunFolder.stdoutFileName, RunFolder.stderrFileName] {
                #expect(fm.fileExists(atPath: folder.appendingPathComponent(name).path))
            }
            #expect(recorder.lines(for: record.id).count == 2)
        }
        #expect(store.load().isEmpty)

        // 履歴に登録して読み直せる。
        let history = HistoryStore(indexURL: tmp.url.appendingPathComponent("history.json"))
        finished.forEach(history.register)
        let loaded = history.loadAll(outputDirectory: out)
        #expect(Set(loaded.map(\.id)) == Set(jobs.map(\.id)))
        #expect(loaded.allSatisfy { $0.status == .done })
    }
}
