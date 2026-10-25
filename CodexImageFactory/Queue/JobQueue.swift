import Foundation
import Synchronization

/// キューの状態の写し。UI はこれを受け取ってそのまま表示する。
struct QueueSnapshot: Sendable, Equatable {
    /// 待機中のジョブ（実行順）。
    var queued: [JobRecord]
    /// 実行中のジョブ（開始順）。
    var running: [JobRecord]
    var isPaused: Bool
    var concurrency: Int

    static let empty = QueueSnapshot(queued: [], running: [], isPaused: false, concurrency: AppSettings.defaults.concurrency)
}

/// キューから UI への通知。
enum QueueEvent: Sendable {
    /// 待機・実行中の一覧や一時停止状態が変わった。
    case snapshot(QueueSnapshot)
    /// 実行中ジョブの stdout / stderr の 1 行。
    case line(jobID: UUID, stream: CodexStream, text: String)
    /// ジョブが終わった（done / failed / cancelled）。run.json は書き終わっている。
    case finished(JobRecord)
    /// レート制限らしきエラーを検出し、キューを一時停止した。
    case rateLimited(jobID: UUID, message: String)
    /// キューが空になった（待機中 0・実行中 0）。1 件以上を処理したあと 1 回だけ。
    case drained
}

/// キューの制御。並列数の上限を守って先頭から順に実行する。
///
/// - 待機中の一覧が変わるたびに QueueStore へ保存する。
/// - 一時停止中は新しく起動しない（実行中のジョブはそのまま走らせる）。
/// - レート制限を検出したら自動で一時停止する。自動リトライはしない。
actor JobQueue {
    nonisolated let events: AsyncStream<QueueEvent>
    private let continuation: AsyncStream<QueueEvent>.Continuation

    private let executor: any JobExecuting
    private let store: QueueStore?
    private var settings: AppSettings

    /// 待機中（実行順）。
    private var queued: [JobRecord] = []
    /// 実行中。executor の呼び出しが返って finish するまで残る（中止を頼んだあとも枠を使う）。
    private var running: [UUID: JobQueueRunningEntry] = [:]
    /// 実行中の開始順。
    private var runningOrder: [UUID] = []
    private var isPaused = false
    /// 前回 `.drained` を出してから 1 件以上終わったか。
    private var processedSinceDrain = false
    private var isShuttingDown = false
    private var shutdownTask: Task<Void, Never>?
    /// 終了処理中に終わったジョブの状態（完了したものは戻さないため）。
    private var finishedDuringShutdown: [UUID: JobStatus] = [:]
    /// レート制限の検出を actor へ届けるまでにわざと待つ時間（テスト用。既定は 0）。
    /// ジョブの終了（finish）が一時停止の Task より先に actor へ着いた場合を、テストで確実に起こすために使う。
    private var rateLimitHandoffDelay: Duration = .zero

    init(executor: any JobExecuting, store: QueueStore?, settings: AppSettings) {
        (events, continuation) = AsyncStream.makeStream(of: QueueEvent.self)
        self.executor = executor
        self.store = store
        self.settings = settings.normalized()
    }

    deinit {
        continuation.finish()
    }

    /// 設定（並列数・タイムアウト・固定指示文など）を差し替える。次に起動するジョブから効く。
    /// 並列数が増えたら、その場で空いた枠のぶん起動する。
    /// 減ったときは実行中のジョブを止めず、上限を下回るまで新しく起動しない。
    func updateSettings(_ settings: AppSettings) {
        self.settings = settings.normalized()
        let started = pump()
        publish(saveQueue: started)
    }

    /// 末尾に追加して、空き枠があれば起動する。
    func enqueue(_ jobs: [JobRecord]) {
        var added = false
        for job in jobs where !contains(job.id) {
            queued.append(Self.queuedCopy(of: job))
            added = true
        }
        guard added else { return }
        pump()
        publish(saveQueue: true)
    }

    /// 前回終了時に保存した待機中ジョブを先頭側に戻し、一時停止状態にする。
    /// 戻すジョブが 1 件も無ければ何もしない（起動のたびに呼んでも、空なら一時停止にならない）。
    func restore(_ jobs: [JobRecord]) {
        var restored: [JobRecord] = []
        for job in jobs where !contains(job.id) && !restored.contains(where: { $0.id == job.id }) {
            restored.append(Self.queuedCopy(of: job))
        }
        guard !restored.isEmpty else { return }
        queued.insert(contentsOf: restored, at: 0)
        isPaused = true
        publish(saveQueue: true)
    }

    /// 待機中ジョブの内容を差し替える（id で探す）。待機中でなければ false。
    @discardableResult
    func update(_ job: JobRecord) -> Bool {
        guard let index = queued.firstIndex(where: { $0.id == job.id }) else { return false }
        queued[index] = Self.queuedCopy(of: job)
        publish(saveQueue: true)
        return true
    }

    /// 待機中ジョブを削除する。待機中でなければ false。
    @discardableResult
    func remove(_ id: UUID) -> Bool {
        guard let index = queued.firstIndex(where: { $0.id == id }) else { return false }
        queued.remove(at: index)
        publish(saveQueue: true)
        return true
    }

    /// 待機中ジョブを 1 つ前へ。
    func moveUp(_ id: UUID) {
        guard let index = queued.firstIndex(where: { $0.id == id }), index > 0 else { return }
        queued.swapAt(index, index - 1)
        publish(saveQueue: true)
    }

    /// 待機中ジョブを 1 つ後ろへ。
    func moveDown(_ id: UUID) {
        guard let index = queued.firstIndex(where: { $0.id == id }), index < queued.count - 1 else { return }
        queued.swapAt(index, index + 1)
        publish(saveQueue: true)
    }

    /// 実行中ジョブを中止する（SIGINT → 3 秒後 SIGKILL は runner 側）。結果は `.finished` で届く。
    func cancel(_ id: UUID) {
        running[id]?.task?.cancel()
    }

    /// 新しいジョブの起動を止める。
    func pause() {
        isPaused = true
        publish(saveQueue: false)
    }

    /// 起動を再開する。終了処理を始めたあとは何もしない。
    func resume() {
        guard !isShuttingDown else { return }
        isPaused = false
        let started = pump()
        publish(saveQueue: started)
    }

    /// テスト用: レート制限の検出を actor へ届けるのを `delay` だけ遅らせる。次に起動するジョブから効く。
    func setRateLimitHandoffDelayForTesting(_ delay: Duration) {
        rateLimitHandoffDelay = delay
    }

    func snapshot() -> QueueSnapshot {
        QueueSnapshot(
            queued: queued,
            running: runningOrder.compactMap { running[$0]?.record },
            isPaused: isPaused,
            concurrency: settings.concurrency
        )
    }

    /// アプリ終了時に呼ぶ。実行中ジョブを中止して終わるのを待ち（最大 `timeout` 秒）、
    /// 中止したジョブは入力内容だけを引き継いだ新しい待機中ジョブとして先頭に戻し、待機中一覧を保存する。
    /// 2 回目以降の呼び出しは、最初の終了処理が終わるのを待つだけ。
    func shutdown(timeout: TimeInterval = 5) async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let task = Task { await self.performShutdown(timeout: timeout) }
        shutdownTask = task
        await task.value
    }

    // MARK: - 内部

    private func performShutdown(timeout: TimeInterval) async {
        isShuttingDown = true
        isPaused = true
        let interrupted = runningOrder.compactMap { running[$0]?.record }
        for id in runningOrder {
            running[id]?.task?.cancel()
        }
        publish(saveQueue: false)

        // 終わるまで待つ（待っている間も finish は actor 上で進む）。止まらないジョブがあっても timeout で諦める。
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(Int(max(0, timeout) * 1000))
        while !running.isEmpty, clock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                break
            }
        }

        // 完了まで行ったもの以外は、新しい待機中ジョブとして先頭に戻す（開始順のまま）。
        let now = Date()
        let retries = interrupted
            .filter { finishedDuringShutdown[$0.id] != .done }
            .enumerated()
            .map { index, job in job.makeRetry(now: now.addingTimeInterval(Double(index) * 0.001)) }
        queued.insert(contentsOf: retries, at: 0)
        publish(saveQueue: true)
    }

    /// 空き枠のぶん先頭から起動する。1 件でも起動したら true（呼び出し側で保存・通知する）。
    @discardableResult
    private func pump() -> Bool {
        var started = false
        while !isPaused, !isShuttingDown, running.count < settings.concurrency, !queued.isEmpty {
            start(queued.removeFirst())
            started = true
        }
        return started
    }

    private func start(_ job: JobRecord) {
        let id = job.id
        var record = job
        record.status = .running
        record.startedAt = Date()
        let flags = JobQueueRunFlags()
        running[id] = JobQueueRunningEntry(record: record, flags: flags)
        runningOrder.append(id)

        let executor = executor
        let settings = settings
        let continuation = continuation
        let handoffDelay = rateLimitHandoffDelay
        // executor は actor の外（グローバルな executor）で走らせる。
        let task = Task.detached {
            let result = await executor.execute(job, settings: settings) { event in
                switch event {
                case .started(let started):
                    Task { await self.jobStarted(id: id, record: started) }
                case .line(let stream, let text):
                    // 行は順番を保つため、Task を挟まずにそのまま流す。
                    continuation.yield(.line(jobID: id, stream: stream, text: text))
                case .rateLimited(let message):
                    flags.markRateLimited()
                    continuation.yield(.rateLimited(jobID: id, message: message))
                    Task {
                        if handoffDelay > .zero {
                            try? await Task.sleep(for: handoffDelay)
                        }
                        await self.rateLimitDetected(id: id)
                    }
                }
            }
            await self.finish(id: id, result: result, flags: flags)
        }
        running[id]?.task = task
    }

    /// `.started` を受けて、実行中レコードにフォルダやコマンドを反映する。
    private func jobStarted(id: UUID, record: JobRecord) {
        guard var entry = running[id] else { return }
        entry.record.outputDir = record.outputDir
        entry.record.commandLine = record.commandLine
        entry.record.command = record.command
        entry.record.fullPrompt = record.fullPrompt
        entry.record.startedAt = record.startedAt ?? entry.record.startedAt
        running[id] = entry
        publish(saveQueue: false)
    }

    /// レート制限を検出したら一時停止する（1 ジョブにつき 1 回）。
    private func rateLimitDetected(id: UUID) {
        guard var entry = running[id], !entry.rateLimitHandled else { return }
        entry.rateLimitHandled = true
        running[id] = entry
        isPaused = true
        publish(saveQueue: false)
    }

    private func finish(id: UUID, result: JobRecord, flags: JobQueueRunFlags) {
        guard let entry = running.removeValue(forKey: id) else { return }
        runningOrder.removeAll { $0 == id }
        // 一時停止の Task より先にここへ来た場合も、次を起動する前に止める。
        if flags.isRateLimited, !entry.rateLimitHandled {
            isPaused = true
        }
        var record = result
        if !record.status.isFinished {
            record.status = .failed
            record.errorSummary = record.errorSummary ?? "実行が途中で終わりました"
        }
        if record.finishedAt == nil {
            record.finishedAt = Date()
        }
        if isShuttingDown {
            finishedDuringShutdown[id] = record.status
        }
        processedSinceDrain = true
        continuation.yield(.finished(record))

        let started = pump()
        publish(saveQueue: started)

        if queued.isEmpty, running.isEmpty, processedSinceDrain, !isShuttingDown {
            processedSinceDrain = false
            continuation.yield(.drained)
        }
    }

    /// 必要なら待機中一覧を保存し、写しを流す。
    private func publish(saveQueue: Bool) {
        if saveQueue {
            store?.save(queued)
        }
        continuation.yield(.snapshot(snapshot()))
    }

    private func contains(_ id: UUID) -> Bool {
        running[id] != nil || queued.contains { $0.id == id }
    }

    /// 待機中として持つ形にする（状態を queued にし、実行時の値を消す）。
    private static func queuedCopy(of job: JobRecord) -> JobRecord {
        var j = job
        j.status = .queued
        j.startedAt = nil
        j.finishedAt = nil
        j.exitCode = nil
        j.outputDir = ""
        j.command = []
        j.commandLine = ""
        j.images = []
        j.lastMessage = ""
        j.errorSummary = nil
        j.codexThreadId = nil
        return j
    }
}

/// 実行中ジョブ 1 件。
private struct JobQueueRunningEntry {
    var record: JobRecord
    var task: Task<Void, Never>?
    var flags: JobQueueRunFlags
    /// このジョブのレート制限で一時停止したか（resume のあとに再び止めないため）。
    var rateLimitHandled = false

    init(record: JobRecord, flags: JobQueueRunFlags) {
        self.record = record
        self.flags = flags
    }
}

/// executor のコールバック（任意のスレッド）と actor の両方から触る印。
private final class JobQueueRunFlags: Sendable {
    private let rateLimited = Mutex(false)

    func markRateLimited() {
        rateLimited.withLock { $0 = true }
    }

    var isRateLimited: Bool {
        rateLimited.withLock { $0 }
    }
}
