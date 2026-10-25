import Foundation
import Synchronization
import Testing
@testable import CodexImageFactory

// MARK: - テスト用の部品

/// スレッドをまたいで値を記録する。
final class UITRecorder<Element: Sendable>: Sendable {
    private let storage = Mutex<[Element]>([])

    func append(_ element: Element) {
        storage.withLock { $0.append(element) }
    }

    var all: [Element] {
        storage.withLock { $0 }
    }
}

/// JobQueue の代わり。呼ばれた操作を記録し、本物と同じように snapshot を流す。
final class UITFakeQueue: JobQueueing {
    struct State: Sendable {
        var queued: [JobRecord] = []
        var running: [JobRecord] = []
        var isPaused = false
        var enqueued: [[JobRecord]] = []
        var restored: [[JobRecord]] = []
        var updates: [JobRecord] = []
        var removed: [UUID] = []
        var settings: [AppSettings] = []
        var cancelled: [UUID] = []
        var movedUp: [UUID] = []
        var movedDown: [UUID] = []
        var pauseCount = 0
        var resumeCount = 0
        var shutdownCount = 0
        /// 呼ばれた順（"settings:<codexPath>" / "enqueue:<件数>" など）。
        var calls: [String] = []
        /// true なら update を失敗させる（実行が始まった想定）。
        var rejectUpdates = false
    }

    let events: AsyncStream<QueueEvent>
    private let continuation: AsyncStream<QueueEvent>.Continuation
    let state = Mutex(State())

    init() {
        (events, continuation) = AsyncStream.makeStream(of: QueueEvent.self)
    }

    var current: State {
        state.withLock { $0 }
    }

    func emit(_ event: QueueEvent) {
        continuation.yield(event)
    }

    private func emitSnapshot() {
        let snapshot = state.withLock {
            QueueSnapshot(queued: $0.queued, running: $0.running, isPaused: $0.isPaused, concurrency: 3)
        }
        continuation.yield(.snapshot(snapshot))
    }

    func updateSettings(_ settings: AppSettings) async {
        state.withLock {
            $0.settings.append(settings)
            $0.calls.append("settings:\(settings.codexPath)")
        }
    }

    func enqueue(_ jobs: [JobRecord]) async {
        state.withLock {
            $0.enqueued.append(jobs)
            $0.queued += jobs
            $0.calls.append("enqueue:\(jobs.count)")
        }
        emitSnapshot()
    }

    func restore(_ jobs: [JobRecord]) async {
        state.withLock {
            $0.restored.append(jobs)
            $0.queued = jobs + $0.queued
            $0.isPaused = true
            $0.calls.append("restore:\(jobs.count)")
        }
        emitSnapshot()
    }

    func update(_ job: JobRecord) async -> Bool {
        let ok = state.withLock { s -> Bool in
            guard !s.rejectUpdates, let index = s.queued.firstIndex(where: { $0.id == job.id }) else { return false }
            s.queued[index] = job
            s.updates.append(job)
            return true
        }
        if ok { emitSnapshot() }
        return ok
    }

    func remove(_ id: UUID) async -> Bool {
        let ok = state.withLock { s -> Bool in
            guard let index = s.queued.firstIndex(where: { $0.id == id }) else { return false }
            s.queued.remove(at: index)
            s.removed.append(id)
            return true
        }
        if ok { emitSnapshot() }
        return ok
    }

    func moveUp(_ id: UUID) async {
        state.withLock { $0.movedUp.append(id) }
    }

    func moveDown(_ id: UUID) async {
        state.withLock { $0.movedDown.append(id) }
    }

    func cancel(_ id: UUID) async {
        state.withLock { $0.cancelled.append(id) }
    }

    func pause() async {
        state.withLock {
            $0.pauseCount += 1
            $0.isPaused = true
            $0.calls.append("pause")
        }
        emitSnapshot()
    }

    func resume() async {
        state.withLock {
            $0.resumeCount += 1
            $0.isPaused = false
            $0.calls.append("resume")
        }
        emitSnapshot()
    }

    func snapshot() async -> QueueSnapshot {
        state.withLock { QueueSnapshot(queued: $0.queued, running: $0.running, isPaused: $0.isPaused, concurrency: 3) }
    }

    func shutdown(timeout: TimeInterval) async {
        state.withLock {
            $0.shutdownCount += 1
            $0.calls.append("shutdown")
        }
    }
}

final class UITFakeNotifier: AppNotifying {
    struct Post: Sendable, Equatable {
        var title: String
        var body: String
    }

    private let recorder = UITRecorder<Post>()
    private let authorizations = Mutex(0)

    var posts: [Post] { recorder.all }
    var authorizationCount: Int { authorizations.withLock { $0 } }

    func requestAuthorization() async {
        authorizations.withLock { $0 += 1 }
    }

    func post(title: String, body: String) async {
        recorder.append(Post(title: title, body: body))
    }
}

/// AppModel を、ユーザーのファイルに触れないダミーの部品で組み立てる。
@MainActor
final class UITHarness {
    let queue = UITFakeQueue()
    let notifier = UITFakeNotifier()
    let pasteboard = UITRecorder<String>()
    let opened = UITRecorder<URL>()
    let revealed = UITRecorder<[URL]>()
    let registered = UITRecorder<JobRecord>()
    let deleted = UITRecorder<JobRecord>()
    let suite = UITDefaultsSuite()
    /// `~` の展開先（一時フォルダ）。
    let home: URL

    var savedQueue: [JobRecord] = []
    var historyRecords: [JobRecord] = []
    var detectedPath: String? = "/fake/bin/codex"
    /// codex の自動検出にかかる時間（ログインシェルが遅い想定）。
    var detectDelay: Duration = .zero
    var login = LoginStatus(loggedIn: true, output: "Logged in using ChatGPT", exitCode: 0)
    var executablePaths: Set<String> = []
    var now = Date(timeIntervalSince1970: 1_793_000_000)

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("UIT-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func cleanUp() {
        suite.remove()
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    func makeFile(_ name: String) throws -> URL {
        let url = home.appendingPathComponent(name)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        return url
    }

    func saveSettings(_ settings: AppSettings) {
        SettingsStore(defaults: suite.defaults).save(settings)
    }

    func makeModel() -> AppModel {
        AppModel(dependencies: dependencies())
    }

    func dependencies() -> AppDependencies {
        let queue = self.queue
        let saved = savedQueue
        let history = historyRecords
        let detected = detectedPath
        let detectDelay = self.detectDelay
        let login = self.login
        let executable = executablePaths
        let home = self.home
        let now = self.now
        let registered = self.registered
        let deleted = self.deleted
        let pasteboard = self.pasteboard
        let opened = self.opened
        let revealed = self.revealed
        return AppDependencies(
            settingsStore: SettingsStore(defaults: suite.defaults),
            makeQueue: { _ in queue },
            loadSavedQueue: { saved },
            loadHistory: { _ in history },
            registerHistory: { registered.append($0) },
            deleteHistory: { deleted.append($0) },
            readLogs: { _ in (stdout: "", stderr: "") },
            detectCodexPath: {
                if detectDelay > .zero {
                    try? await Task.sleep(for: detectDelay)
                }
                return detected
            },
            invalidateCodexDetection: {},
            codexEnvironment: { ["HOME": home.path] },
            loginStatus: { _, _ in login },
            isExecutableFile: { executable.contains($0) },
            homeDirectory: home,
            notifier: notifier,
            copyToPasteboard: { pasteboard.append($0) },
            openFile: { opened.append($0) },
            revealInFinder: { revealed.append($0) },
            createDirectory: { _ in },
            now: { now }
        )
    }
}

/// 同時に走った数を数える（履歴の索引の読み書きが重ならないことの確認用）。
final class UITOverlapTracker: Sendable {
    private struct Counts {
        var active = 0
        var maxActive = 0
        var completed = 0
    }

    private let counts = Mutex(Counts())

    func run(_ body: () -> Void) {
        counts.withLock {
            $0.active += 1
            $0.maxActive = max($0.maxActive, $0.active)
        }
        body()
        counts.withLock {
            $0.active -= 1
            $0.completed += 1
        }
    }

    var maxActive: Int { counts.withLock { $0.maxActive } }
    var completed: Int { counts.withLock { $0.completed } }
}

/// 条件が満たされるまで待つ（非同期の Task やイベントの反映待ち）。
@MainActor
func uitWaitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline {
            return false
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

func uitRecord(
    status: JobStatus = .done,
    slug: String = "kina-mascot",
    prompt: String = "猫のマスコット",
    commandLine: String = "",
    images: [String] = [],
    errorSummary: String? = nil,
    createdAt: Date = Date(timeIntervalSince1970: 1_793_000_000)
) -> JobRecord {
    JobRecord(
        status: status,
        createdAt: createdAt,
        startedAt: status == .queued ? nil : createdAt.addingTimeInterval(1),
        finishedAt: status.isFinished ? createdAt.addingTimeInterval(63) : nil,
        slug: slug,
        prompt: prompt,
        preset: "プリセット",
        fullPrompt: "プリセット\n\n\(prompt)",
        count: 2,
        aspect: .landscape,
        background: .white,
        referenceImages: ["/tmp/ref.png"],
        commandLine: commandLine,
        exitCode: status == .done ? 0 : (status == .failed ? 1 : nil),
        outputDir: status == .queued ? "" : "/tmp/out/\(slug)",
        images: images,
        errorSummary: errorSummary
    )
}

// MARK: - 参照画像

@Suite("AppModel 参照画像")
@MainActor
struct UITReferenceImageTests {
    @Test func rejectsMissingNonImageAndFolder() throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        let txt = try h.makeFile("notes.txt")

        #expect(!model.addReferencePath(h.home.appendingPathComponent("missing.png").path))
        #expect(model.referenceError?.hasPrefix("ファイルが見つかりません") == true)

        #expect(!model.addReferencePath(txt.path))
        #expect(model.referenceError?.hasPrefix("画像ファイル（png / jpg / jpeg / webp）だけ") == true)

        #expect(!model.addReferencePath(h.home.path))
        #expect(model.referenceError?.hasPrefix("フォルダは追加できません") == true)

        #expect(!model.addReferencePath("images/a.png"))
        #expect(model.referenceError?.contains("から始まるパス") == true)

        #expect(!model.addReferencePath("   "))
        #expect(model.referenceError == "パスを入力してください。")

        #expect(model.draft.referenceImages.isEmpty)
    }

    @Test func acceptsExistingImageAndClearsError() throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        let png = try h.makeFile("a.png")
        #expect(!model.addReferencePath("/nope.png"))
        #expect(model.addReferencePath(png.path))
        #expect(model.referenceError == nil)
        #expect(model.draft.referenceImages == [ReferenceImageValidator.standardize(png.path)])
    }

    @Test func expandsTildeAgainstHome() throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        let file = try h.makeFile("ref.PNG")
        #expect(model.addReferencePath("~/ref.PNG"))
        #expect(model.draft.referenceImages == [ReferenceImageValidator.standardize(file.path)])
        #expect(FileManager.default.fileExists(atPath: model.draft.referenceImages[0]))
    }

    @Test func acceptsQuotedFileURLAndEscapedPaths() throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        let quoted = try h.makeFile("quoted.jpg")
        let viaURL = try h.makeFile("url.webp")
        let spaced = try h.makeFile("with space.jpeg")
        #expect(model.addReferencePath("  \"\(quoted.path)\"  "))
        #expect(model.addReferencePath(viaURL.absoluteString))
        #expect(model.addReferencePath(spaced.path.replacingOccurrences(of: " ", with: "\\ ")))
        #expect(model.draft.referenceImages.map { ($0 as NSString).lastPathComponent } == ["quoted.jpg", "url.webp", "with space.jpeg"])
    }

    @Test func limitsToFourAndRejectsDuplicates() throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        let files = try ["a.png", "b.jpg", "c.jpeg", "d.webp", "e.png"].map { try h.makeFile($0) }

        #expect(model.addReferencePath(files[0].path))
        #expect(!model.addReferencePath(files[0].path))
        #expect(model.referenceError?.hasPrefix("すでに追加されています") == true)
        // 書き方が違っても同じファイルなら重複。
        #expect(!model.addReferencePath(h.home.path + "/./a.png"))

        for file in files[1...3] {
            #expect(model.addReferencePath(file.path))
        }
        #expect(model.draft.referenceImages.count == 4)
        #expect(!model.addReferencePath(files[4].path))
        #expect(model.referenceError == "参照画像は最大 4 枚までです。")
        #expect(model.draft.referenceImages.count == 4)

        model.removeReference(at: 0)
        #expect(model.draft.referenceImages.count == 3)
        #expect(model.addReferencePath(files[4].path))
        #expect(model.draft.referenceImages.count == 4)
    }

    @Test func dropAddsImagesAndReportsTheRest() throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        let png = try h.makeFile("drop.png")
        let txt = try h.makeFile("drop.txt")
        #expect(model.addReferenceURLs([png, txt]))
        #expect(model.draft.referenceImages.count == 1)
        #expect(model.referenceError?.contains("drop.txt") == true)
        #expect(!model.addReferenceURLs([txt]))
    }

    @Test func pathFieldIsClearedOnlyOnSuccess() throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        let png = try h.makeFile("field.png")
        model.referencePathInput = "/does/not/exist.png"
        model.addReferenceFromInput()
        #expect(model.referencePathInput == "/does/not/exist.png")
        #expect(model.referenceError != nil)
        model.referencePathInput = png.path
        model.addReferenceFromInput()
        #expect(model.referencePathInput == "")
        #expect(model.referenceError == nil)
    }
}

// MARK: - 追加・編集・再利用

@Suite("AppModel 入力")
@MainActor
struct UITInputTests {
    @Test func addSingleClearsPromptAndEnqueuesExactlyOneJob() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.settings.stylePreset = "水彩"
        model.draft = JobDraft(prompt: "  猫のマスコット  ", slug: "kina mascot", count: 2, aspect: .landscape, background: .white)

        await model.addSingle()

        #expect(model.draft.prompt == "")
        #expect(model.draft.slug == "")
        // 枚数・サイズ・背景は次のプロンプトでも使うので残す。
        #expect(model.draft.count == 2)
        #expect(model.draft.aspect == .landscape)
        #expect(model.inputMessage?.hasPrefix("1 件をキューに追加しました") == true)

        let enqueued = h.queue.current.enqueued
        #expect(enqueued.count == 1)
        #expect(enqueued.first?.count == 1)
        let job = try #require(enqueued.first?.first)
        #expect(job.status == .queued)
        #expect(job.prompt == "猫のマスコット")
        #expect(job.slug == "kina-mascot")
        #expect(job.count == 2)
        #expect(job.aspect == .landscape)
        #expect(job.background == .white)
        #expect(job.preset == "水彩")
        #expect(job.createdAt == h.now)
        #expect(job.fullPrompt.hasPrefix("水彩\n\n猫のマスコット\n\n"))

        #expect(await uitWaitUntil { model.queued.map(\.id) == [job.id] })
        #expect(model.queueSummaryText == "待機中 1 件 · 実行中 0 件 · 並列数 3")
    }

    @Test func addSingleWithEmptyPromptDoesNothing() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.draft.prompt = " \n\t "
        await model.addSingle()
        await model.addBatch()
        #expect(h.queue.current.enqueued.isEmpty)
        #expect(model.inputMessage == nil)
        #expect(!model.draft.canSubmit)
    }

    @Test func addBatchCreatesOneJobPerBlock() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.draft.prompt = "赤い猫\n\n青い犬\n   \n緑の鳥\nしっぽ長め\n"
        model.draft.slug = "pets"
        model.draft.count = 4
        #expect(model.draft.batchCount == 3)

        await model.addBatch()

        let enqueued = h.queue.current.enqueued
        #expect(enqueued.count == 1)
        let jobs = enqueued.first ?? []
        #expect(jobs.map(\.prompt) == ["赤い猫", "青い犬", "緑の鳥\nしっぽ長め"])
        #expect(jobs.map(\.slug) == ["pets-1", "pets-2", "pets-3"])
        #expect(jobs.allSatisfy { $0.count == 4 })
        #expect(Set(jobs.map(\.id)).count == 3)
        #expect(model.draft.prompt.isEmpty)
        #expect(model.draft.slug.isEmpty)
        #expect(model.inputMessage == "3 件をキューに追加しました")
    }

    @Test func enqueueWaitsForCodexPathBeforeAdding() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        h.detectedPath = "/fake/bin/codex"
        let model = h.makeModel()
        model.start()
        model.draft.prompt = "すぐ追加"
        await model.addSingle()
        let calls = h.queue.current.calls
        let settingsIndex = try #require(calls.firstIndex(of: "settings:/fake/bin/codex"))
        let enqueueIndex = try #require(calls.firstIndex(of: "enqueue:1"))
        #expect(settingsIndex < enqueueIndex)
    }

    @Test func editThenSaveUpdatesTheQueuedJob() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.settings.stylePreset = "古いプリセット"
        model.draft.prompt = "最初のプロンプト"
        model.draft.slug = "first"
        await model.addSingle()
        let original = try #require(h.queue.current.enqueued.first?.first)
        #expect(await uitWaitUntil { model.queued.count == 1 })

        model.settings.stylePreset = "新しいプリセット"
        model.draft.prompt = "書きかけ"
        model.beginEditing(original.id)

        #expect(model.isEditing)
        #expect(model.editingJobID == original.id)
        #expect(model.draft.prompt == "最初のプロンプト")
        #expect(model.draft.slug == "first")
        #expect(model.editingStatusText?.contains("「first」を編集中") == true)

        // 編集中は「生成」で新しいジョブを作らない。
        await model.addSingle()
        #expect(h.queue.current.enqueued.count == 1)

        model.draft.prompt = "直したプロンプト"
        model.draft.count = 4
        model.draft.background = .unspecified
        await model.saveEdit()

        let updated = try #require(h.queue.current.updates.last)
        #expect(h.queue.current.updates.count == 1)
        #expect(updated.id == original.id)
        #expect(updated.prompt == "直したプロンプト")
        #expect(updated.count == 4)
        #expect(updated.background == .unspecified)
        #expect(updated.slug == "first")
        #expect(updated.preset == "古いプリセット")
        #expect(updated.createdAt == original.createdAt)
        #expect(updated.fullPrompt.contains("直したプロンプト"))

        #expect(!model.isEditing)
        #expect(model.draft.prompt == "書きかけ")
        #expect(model.inputMessage == "「first」の変更を保存しました")
        #expect(h.queue.current.enqueued.count == 1)
        #expect(await uitWaitUntil { model.queued.first?.prompt == "直したプロンプト" })
    }

    @Test func saveEditFailsWhenTheJobIsNoLongerQueued() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.draft.prompt = "元"
        model.draft.slug = "late"
        await model.addSingle()
        let job = try #require(h.queue.current.enqueued.first?.first)
        #expect(await uitWaitUntil { model.queued.count == 1 })

        model.beginEditing(job.id)
        model.draft.prompt = "直した"
        h.queue.state.withLock { $0.rejectUpdates = true }
        await model.saveEdit()

        #expect(!model.isEditing)
        #expect(model.draft.prompt == "直した")
        #expect(model.inputMessage?.contains("保存できませんでした") == true)
        #expect(h.queue.current.updates.isEmpty)
    }

    @Test func cancelEditingRestoresTheDraft() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.draft.prompt = "ジョブ"
        await model.addSingle()
        let job = try #require(h.queue.current.enqueued.first?.first)
        #expect(await uitWaitUntil { model.queued.count == 1 })

        model.draft.prompt = "書きかけ"
        model.beginEditing(job.id)
        model.draft.prompt = "捨てる変更"
        model.cancelEditing()

        #expect(!model.isEditing)
        #expect(model.draft.prompt == "書きかけ")
        #expect(h.queue.current.updates.isEmpty)
    }

    @Test func removingTheEditedJobEndsEditing() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.draft.prompt = "消す"
        model.draft.slug = "gone"
        await model.addSingle()
        let job = try #require(h.queue.current.enqueued.first?.first)
        #expect(await uitWaitUntil { model.queued.count == 1 })
        model.beginEditing(job.id)
        model.select(job.id)

        await model.removeQueued(job.id)

        #expect(!model.isEditing)
        #expect(model.selectedJobID == nil)
        #expect(h.queue.current.removed == [job.id])
        #expect(model.queueMessage == "待機中ジョブ「gone」を削除しました")
    }

    @Test func reusePromptFillsTheDraft() throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        let record = uitRecord(status: .failed, slug: "20261024-153012", prompt: "再利用する")
        model.reusePrompt(record)
        #expect(model.draft == JobDraft(
            prompt: "再利用する",
            slug: "",
            count: 2,
            aspect: .landscape,
            background: .white,
            referenceImages: ["/tmp/ref.png"]
        ))
        #expect(model.inputMessage == "「20261024-153012」のプロンプトを入力欄に戻しました")

        model.reusePrompt(uitRecord(slug: "named"))
        #expect(model.draft.slug == "named")
    }

    @Test func copyCommandWritesExactlyTheCommandLine() throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        let line = "/fake/bin/codex exec -C '/tmp/a b' --json -- 'it'\\''s'"
        model.copyCommand(uitRecord(commandLine: line))
        #expect(h.pasteboard.all == [line])
        #expect(model.detailMessage == "コマンドをコピーしました")

        model.copyPath("/tmp/out/x-01.png")
        #expect(h.pasteboard.all == [line, "/tmp/out/x-01.png"])
    }

    @Test func revealInFinderSelectsExistingImagesOrFolder() throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        let image = try h.makeFile("x-01.png")
        var record = uitRecord(images: [image.path, h.home.appendingPathComponent("missing.png").path])
        record.outputDir = h.home.path
        model.revealInFinder(record)
        record.images = []
        model.revealInFinder(record)
        record.outputDir = "/does/not/exist"
        model.revealInFinder(record)
        #expect(h.revealed.all.map { $0.map(\.lastPathComponent) } == [["x-01.png"], [h.home.lastPathComponent]])
        #expect(model.detailMessage?.hasPrefix("フォルダが見つかりません") == true)
    }

    @Test func retryEnqueuesAFreshCopy() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        let failed = uitRecord(status: .failed, slug: "oops", commandLine: "x", errorSummary: "boom")
        await model.retry(failed)
        let job = try #require(h.queue.current.enqueued.first?.first)
        #expect(job.id != failed.id)
        #expect(job.status == .queued)
        #expect(job.prompt == failed.prompt)
        #expect(job.slug == "oops")
        #expect(job.referenceImages == failed.referenceImages)
        #expect(job.commandLine.isEmpty)
        #expect(job.errorSummary == nil)
        #expect(model.queueMessage == "「oops」を再試行としてキューに追加しました")
    }
}

// MARK: - キューからの通知

@Suite("AppModel キューの通知")
@MainActor
struct UITQueueEventTests {
    @Test func linesFillTheLiveLogAndFinishedGoesToHistory() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        let running = uitRecord(status: .running, slug: "live")
        model.handle(.snapshot(QueueSnapshot(queued: [], running: [running], isPaused: false, concurrency: 3)))
        #expect(model.running.map(\.id) == [running.id])
        #expect(model.liveLog(for: running.id) != nil)

        let json = #"{"type":"thread.started","thread_id":"t-1"}"#
        model.handle(.line(jobID: running.id, stream: .stdout, text: json))
        model.handle(.line(jobID: running.id, stream: .stderr, text: "warn"))
        let log = try #require(model.liveLog(for: running.id))
        #expect(log.raw == [json, "[stderr] warn"])
        #expect(log.formatted == ["[thread.started] thread_id=t-1", "[stderr] warn"])

        let older = uitRecord(status: .done, slug: "older")
        model.handle(.finished(older))
        var finished = running
        finished.status = .done
        finished.finishedAt = running.startedAt?.addingTimeInterval(30)
        model.handle(.finished(finished))

        #expect(model.history.map(\.id) == [finished.id, older.id])
        #expect(model.running.isEmpty)
        // 詳細ペイン用にライブログは残す。
        #expect(model.liveLog(for: finished.id)?.raw.count == 2)
        #expect(await uitWaitUntil { h.registered.all.count == 2 })
        #expect(Set(h.registered.all.map(\.id)) == [finished.id, older.id])

        model.select(finished.id)
        #expect(model.selectedJob?.status == .done)
    }

    @Test func drainedPostsOneNotificationWithCounts() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.handle(.finished(uitRecord(status: .done, slug: "a")))
        model.handle(.finished(uitRecord(status: .failed, slug: "b")))
        model.handle(.finished(uitRecord(status: .failed, slug: "c")))
        model.handle(.drained)

        #expect(await uitWaitUntil { h.notifier.posts.count == 1 })
        #expect(h.notifier.posts.first == UITFakeNotifier.Post(
            title: "キューのジョブがすべて終わりました",
            body: "完了 1 件 · 失敗 2 件"
        ))

        // 前回から何も終わっていなければ出さない。
        model.handle(.drained)
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.notifier.posts.count == 1)

        model.handle(.finished(uitRecord(status: .cancelled, slug: "d")))
        model.handle(.drained)
        #expect(await uitWaitUntil { h.notifier.posts.count == 2 })
        #expect(h.notifier.posts.last?.body == "完了 0 件 · 失敗 0 件 · 中止 1 件")
    }

    @Test func rateLimitShowsBannerAndResumeClearsIt() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        let job = uitRecord(status: .running, slug: "busy")
        model.handle(.snapshot(QueueSnapshot(queued: [], running: [job], isPaused: true, concurrency: 3)))
        model.handle(.rateLimited(jobID: job.id, message: "429 Too Many Requests"))
        #expect(model.rateLimitNotice == RateLimitNotice(jobID: job.id, slug: "busy", message: "429 Too Many Requests"))
        #expect(model.queueStateText == "状態: 一時停止中")

        await model.resumeAll()
        #expect(model.rateLimitNotice == nil)
        #expect(h.queue.current.resumeCount == 1)
        #expect(await uitWaitUntil { !model.isPaused })
        #expect(model.queueStateText.hasPrefix("状態: 実行中"))

        model.handle(.rateLimited(jobID: job.id, message: "rate limit"))
        model.dismissRateLimitNotice()
        #expect(model.rateLimitNotice == nil)
    }

    @Test func eventsFromTheQueueStreamAreMirrored() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        let queued = uitRecord(status: .queued, slug: "waiting")
        h.queue.emit(.snapshot(QueueSnapshot(queued: [queued], running: [], isPaused: true, concurrency: 3)))
        #expect(await uitWaitUntil { model.isPaused && model.queued.map(\.id) == [queued.id] })
        #expect(model.needsGracefulShutdown == false)
        h.queue.emit(.snapshot(QueueSnapshot(queued: [], running: [queued], isPaused: false, concurrency: 3)))
        #expect(await uitWaitUntil { model.running.count == 1 })
        #expect(model.needsGracefulShutdown)
        await model.shutdown()
        #expect(h.queue.current.shutdownCount == 1)
    }

    @Test func historyIndexWorkNeverOverlaps() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let tracker = UITOverlapTracker()
        var deps = h.dependencies()
        deps.registerHistory = { _ in tracker.run { usleep(20_000) } }
        deps.loadHistory = { _ in
            tracker.run { usleep(20_000) }
            return []
        }
        deps.deleteHistory = { _ in tracker.run { usleep(20_000) } }
        let model = AppModel(dependencies: deps)
        model.reloadHistory()
        let records = (0..<4).map { uitRecord(slug: "s\($0)") }
        for record in records {
            model.handle(.finished(record))
        }
        await model.deleteHistory(records[0])
        #expect(await uitWaitUntil { tracker.completed == 6 })
        #expect(tracker.maxActive == 1)
    }

    @Test func pauseAllCallsTheQueue() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        await model.pauseAll()
        #expect(h.queue.current.pauseCount == 1)
        #expect(await uitWaitUntil { model.isPaused })
        let id = UUID()
        await model.moveUp(id)
        await model.moveDown(id)
        await model.cancel(id)
        #expect(h.queue.current.movedUp == [id])
        #expect(h.queue.current.movedDown == [id])
        #expect(h.queue.current.cancelled == [id])
    }
}

// MARK: - 起動・設定・履歴

@Suite("AppModel 起動と設定")
@MainActor
struct UITStartupAndSettingsTests {
    @Test func startRestoresTheSavedQueuePaused() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let a = uitRecord(status: .queued, slug: "a")
        let b = uitRecord(status: .queued, slug: "b")
        h.savedQueue = [a, b]
        let model = h.makeModel()
        model.start()
        model.start()

        #expect(await uitWaitUntil { model.restoredNotice != nil })
        #expect(model.restoredNotice == "前回の待機中ジョブを 2 件復元しました（一時停止中）。「再開」で実行します。")
        #expect(h.queue.current.restored == [[a, b]])
        #expect(await uitWaitUntil { model.isPaused && model.queued.count == 2 })
        #expect(model.queueStateText == "状態: 一時停止中")
        #expect(await uitWaitUntil { h.notifier.authorizationCount == 1 })

        await model.resumeAll()
        #expect(model.restoredNotice == nil)
    }

    @Test func startWithoutSavedJobsShowsNoRestoreMessage() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.start()
        #expect(await uitWaitUntil { model.codexCheck != .checking })
        #expect(model.restoredNotice == nil)
        #expect(h.queue.current.restored.isEmpty)
    }

    @Test func startLoadsHistory() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let newer = uitRecord(slug: "newer")
        let older = uitRecord(status: .failed, slug: "older")
        h.historyRecords = [newer, older]
        let model = h.makeModel()
        model.start()
        #expect(await uitWaitUntil { model.history.map(\.id) == [newer.id, older.id] && !model.isLoadingHistory })
    }

    @Test func loggedInCodexPushesTheDetectedPath() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.start()
        #expect(await uitWaitUntil {
            model.codexCheck == .loggedIn(path: "/fake/bin/codex", output: "Logged in using ChatGPT")
        })
        #expect(model.detectedCodexPath == "/fake/bin/codex")
        #expect(model.effectiveSettings.codexPath == "/fake/bin/codex")
        #expect(h.queue.current.settings.last?.codexPath == "/fake/bin/codex")
        #expect(model.codexCheck.label == "ログイン済み（Logged in using ChatGPT）")
    }

    @Test func missingCodexIsReported() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        h.detectedPath = nil
        let model = h.makeModel()
        model.start()
        #expect(await uitWaitUntil { model.codexCheck == .missing })
        #expect(model.codexPathStatusText.contains("自動検出できませんでした"))
    }

    @Test func notLoggedInShowsTheStatusOutput() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        h.login = LoginStatus(loggedIn: false, output: "Not logged in\n", exitCode: 1)
        let model = h.makeModel()
        model.start()
        #expect(await uitWaitUntil {
            model.codexCheck == .notLoggedIn(path: "/fake/bin/codex", output: "Not logged in")
        })
    }

    @Test func manualCodexPathIsExpandedAndChecked() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        var settings = AppSettings.defaults
        settings.codexPath = "~/bin/codex"
        h.saveSettings(settings)
        let expected = h.home.appendingPathComponent("bin/codex").path
        let model = h.makeModel()
        #expect(model.manualCodexPath == expected)
        model.start()
        #expect(await uitWaitUntil { model.codexCheck == .invalidPath(expected) })
        #expect(model.effectiveSettings.codexPath == expected)
    }

    @Test func manualExecutableCodexPathIsUsed() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        var settings = AppSettings.defaults
        settings.codexPath = "/opt/codex"
        h.saveSettings(settings)
        h.executablePaths = ["/opt/codex"]
        let model = h.makeModel()
        model.start()
        #expect(await uitWaitUntil { model.codexCheck == .loggedIn(path: "/opt/codex", output: "Logged in using ChatGPT") })
        #expect(model.codexPathStatusText == "入力したパスを使います: /opt/codex")
    }

    @Test func settingsChangesArePersistedAndPushed() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.settings.concurrency = 6
        model.settings.useEphemeral = true
        model.settings.model = "gpt-test"
        await model.waitUntilQueueReady()

        let stored = SettingsStore(defaults: h.suite.defaults).load()
        #expect(stored.concurrency == 6)
        #expect(stored.useEphemeral)
        #expect(stored.model == "gpt-test")
        let pushed = try #require(h.queue.current.settings.last)
        #expect(pushed.concurrency == 6)
        #expect(pushed.useEphemeral)
        #expect(pushed.model == "gpt-test")
        #expect(model.queueSummaryText == "待機中 0 件 · 実行中 0 件 · 並列数 6")

        // 変わっていなければ渡さない。
        let count = h.queue.current.settings.count
        model.settings.concurrency = 6
        await model.waitUntilQueueReady()
        #expect(h.queue.current.settings.count == count)
    }

    @Test func autoDetectClearsTheManualPath() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.settings.codexPath = "/somewhere/codex"
        model.autoDetectCodexPath()
        #expect(model.settings.codexPath == "")
        #expect(await uitWaitUntil { model.codexCheck == .loggedIn(path: "/fake/bin/codex", output: "Logged in using ChatGPT") })
    }

    @Test func timeoutMinutesAreValidated() throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        #expect(model.timeoutMinutesText == "10")

        model.timeoutMinutesText = "15"
        #expect(model.settings.timeoutSeconds == 900)
        #expect(model.timeoutError == nil)

        model.timeoutMinutesText = "abc"
        #expect(model.timeoutError != nil)
        #expect(model.settings.timeoutSeconds == 900)

        model.timeoutMinutesText = "0.2"
        #expect(model.timeoutError != nil)
        #expect(model.settings.timeoutSeconds == 900)

        model.timeoutMinutesText = "0.5"
        #expect(model.timeoutError == nil)
        #expect(model.settings.timeoutSeconds == 30)

        model.timeoutMinutesText = "２０"
        #expect(model.timeoutError == nil)
        #expect(model.settings.timeoutSeconds == 1200)

        #expect(AppModel.minutesText(fromSeconds: 600) == "10")
        #expect(AppModel.minutesText(fromSeconds: 90) == "1.5")
    }

    @Test func instructionTemplateCanBeReset() throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.settings.instructionTemplate = "独自の指示"
        model.resetInstructionTemplate()
        #expect(model.settings.instructionTemplate == AppSettings.defaultInstructionTemplate)
    }

    @Test func outputDirectoryUnderHomeUsesTilde() throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.setOutputDirectory(h.home.appendingPathComponent("Pictures/Out", isDirectory: true))
        #expect(model.settings.outputDirectory == "~/Pictures/Out")
        model.setOutputDirectory(URL(fileURLWithPath: "/Volumes/Disk/Out", isDirectory: true))
        #expect(model.settings.outputDirectory == "/Volumes/Disk/Out")
    }

    @Test func deleteHistoryRemovesTheRecord() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let record = uitRecord(slug: "bye")
        h.historyRecords = [record]
        let model = h.makeModel()
        model.start()
        #expect(await uitWaitUntil { model.history.count == 1 })
        model.select(record.id)

        await model.deleteHistory(record)

        #expect(model.history.isEmpty)
        #expect(model.selectedJobID == nil)
        #expect(h.deleted.all.map(\.id) == [record.id])
        #expect(model.queueMessage == "履歴から「bye」を削除しました（画像は残しています）")
    }

    @Test func historyFinishedDuringLoadIsKept() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let loaded = uitRecord(slug: "loaded")
        h.historyRecords = [loaded]
        let model = h.makeModel()
        let fresh = uitRecord(slug: "fresh")
        model.handle(.finished(fresh))
        model.reloadHistory()
        #expect(await uitWaitUntil { !model.isLoadingHistory })
        #expect(model.history.map(\.id) == [fresh.id, loaded.id])
    }
}

// MARK: - ログ・表示

@Suite("ログと表示")
struct UITLogAndFormatTests {
    @Test func displayKeepsOnlyTheTail() {
        let d = LogDisplayText.make(lines: (1...10).map(String.init), alreadyDropped: 5, limit: 3)
        #expect(d.text == "8\n9\n10")
        #expect(d.shownLines == 3)
        #expect(d.omittedLines == 12)
        #expect(d.note == "古い 12 行は省略し、最後の 3 行を表示しています。")
        #expect(LogDisplayText.make(lines: ["a"]).note == nil)
    }

    @Test func loadedRunLogFormatsStdoutAndPrefixesStderr() {
        let log = LoadedRunLog.make(stdout: "{\"type\":\"turn.started\"}\nplain\n", stderr: "oops\r\n")
        #expect(log.raw == ["{\"type\":\"turn.started\"}", "plain", "[stderr] oops"])
        #expect(log.formatted == ["[turn.started]", "plain", "[stderr] oops"])
        #expect(log.omittedLines == 0)
        #expect(log.display(.raw).text == "{\"type\":\"turn.started\"}\nplain\n[stderr] oops")
        #expect(LoadedRunLog.make(stdout: "", stderr: "").raw.isEmpty)
    }

    @Test func loadedRunLogKeepsTheLastLines() {
        let stdout = (1...10).map { "o\($0)" }.joined(separator: "\n")
        let log = LoadedRunLog.make(stdout: stdout, stderr: "e1\ne2", limit: 5)
        #expect(log.raw == ["o8", "o9", "o10", "[stderr] e1", "[stderr] e2"])
        #expect(log.omittedLines == 7)
    }

    @MainActor
    @Test func liveLogDropsOldLines() {
        let log = LiveJobLog()
        for i in 0..<5600 {
            log.append(stream: .stderr, text: "\(i)")
        }
        #expect(log.raw.count >= LiveJobLog.maxLines)
        #expect(log.raw.count <= LiveJobLog.maxLines + 500)
        #expect(log.raw.count == log.formatted.count)
        #expect(log.droppedCount + log.raw.count == 5600)
        #expect(log.raw.last == "[stderr] 5599")
        #expect(log.display(.formatted).shownLines == LogDisplayText.displayLimit)
    }

    @Test func historyLineReadsAsOneLine() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 15, minute: 30, second: 5)))
        var record = uitRecord(status: .done, slug: "kina-mascot", images: ["/a-01.png", "/a-02.png"], createdAt: start)
        record.startedAt = start
        record.finishedAt = start.addingTimeInterval(62)
        #expect(UIDisplayFormat.historyLine(record, calendar: calendar) == "完了 · kina-mascot · 1:02 · 2 枚 · 10/24 15:30")
        record.status = .failed
        record.images = []
        #expect(UIDisplayFormat.historyLine(record, calendar: calendar) == "失敗 · kina-mascot · 1:02 · 0 枚 · 10/24 15:30")
        #expect(UIDisplayFormat.fullDate(start, calendar: calendar) == "2026/10/24 15:30:05")
        #expect(UIDisplayFormat.fullDate(nil) == "—")
        #expect(UIDisplayFormat.firstLine("\n  一行目 \n二行目") == "一行目")
    }

    @Test func codexStateLabelsAreText() {
        #expect(CodexCheckState.missing.label == "codex が見つかりません")
        #expect(CodexCheckState.notLoggedIn(path: "/c", output: "Not logged in").label == "未ログイン（Not logged in）")
        #expect(CodexCheckState.checking.label == "確認中…")
    }
}
