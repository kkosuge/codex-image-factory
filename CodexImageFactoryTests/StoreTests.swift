import Foundation
import Synchronization
import Testing
@testable import CodexImageFactory

// MARK: - テスト用の共通部品（queue 担当のテストで使う）

/// テストごとの一時フォルダ。
struct QTempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("QTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func sub(_ name: String) -> URL {
        url.appendingPathComponent(name, isDirectory: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// スレッドをまたいで値を集める入れ物。
final class QLog<T: Sendable>: Sendable {
    private let items = Mutex<[T]>([])

    func append(_ item: T) {
        items.withLock { $0.append(item) }
    }

    var all: [T] {
        items.withLock { $0 }
    }

    var count: Int {
        items.withLock { $0.count }
    }
}

/// 条件が満たされるまで待つ。満たされなければ false。
func qWaitUntil(
    timeout: Duration = .seconds(10),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// PNG らしいバイト列（先頭が PNG のシグネチャ）。
func qPNGData(_ seed: UInt8 = 0, size: Int = 64) -> Data {
    Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: seed, count: size)
}

func qMakeJob(
    slug: String,
    prompt: String = "猫のイラスト",
    count: Int = 1,
    referenceImages: [String] = [],
    createdAt: Date = Date()
) -> JobRecord {
    JobRecord(
        createdAt: createdAt,
        slug: slug,
        prompt: prompt,
        preset: "",
        count: count,
        aspect: .square,
        background: .transparent,
        referenceImages: referenceImages
    )
}

func qSettings(
    outputDirectory: URL,
    codexPath: String = "",
    concurrency: Int = 3,
    timeoutSeconds: Int = 600
) -> AppSettings {
    var s = AppSettings.defaults
    s.outputDirectory = outputDirectory.path
    s.codexPath = codexPath
    s.concurrency = concurrency
    s.timeoutSeconds = timeoutSeconds
    return s
}

/// 実行権限付きのダミー codex（中身は使わない。存在確認だけを通すため）。
func qMakeFakeCodex(in dir: URL) throws -> String {
    let url = dir.appendingPathComponent("codex")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

/// 終わった状態のレコードを持つフォルダを作る。
@discardableResult
func qWriteRunFolder(
    in parent: URL,
    name: String,
    record: JobRecord,
    images: [String] = [],
    extraFiles: Bool = true
) throws -> URL {
    let folder = parent.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var r = record
    r.outputDir = folder.path
    r.images = images.map { folder.appendingPathComponent($0).path }
    for image in images {
        try qPNGData().write(to: folder.appendingPathComponent(image))
    }
    if extraFiles {
        try Data("prompt".utf8).write(to: folder.appendingPathComponent(RunFolder.promptFileName))
        try Data("{}\n".utf8).write(to: folder.appendingPathComponent(RunFolder.stdoutFileName))
        try Data("err\n".utf8).write(to: folder.appendingPathComponent(RunFolder.stderrFileName))
        try Data("a-01.png\n".utf8).write(to: folder.appendingPathComponent(RunFolder.lastMessageFileName))
    }
    try RunFolder.writeRecord(r, to: folder)
    return folder
}

func qFinishedRecord(slug: String, startedAt: Date, status: JobStatus = .done, id: UUID = UUID()) -> JobRecord {
    var r = qMakeJob(slug: slug, createdAt: startedAt.addingTimeInterval(-10))
    r.id = id
    r.status = status
    r.startedAt = startedAt
    r.finishedAt = status.isFinished ? startedAt.addingTimeInterval(60) : nil
    r.exitCode = status == .done ? 0 : nil
    return r
}

// MARK: - RunFolder

@Suite("RunFolder")
struct RunFolderTests {
    @Test func createsFolderAndOutputDirectory() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.sub("a/b/out")
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let folder = try RunFolder.create(in: out, slug: "kina-mascot", startedAt: date)
        #expect(folder.lastPathComponent == Slug.folderName(slug: "kina-mascot", startedAt: date))
        #expect(folder.deletingLastPathComponent().standardizedFileURL.path == out.standardizedFileURL.path)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) && isDir.boolValue)
    }

    @Test func addsSuffixWhenNameExists() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let base = Slug.folderName(slug: "a", startedAt: date)
        let f1 = try RunFolder.create(in: tmp.url, slug: "a", startedAt: date)
        let f2 = try RunFolder.create(in: tmp.url, slug: "a", startedAt: date)
        let f3 = try RunFolder.create(in: tmp.url, slug: "a", startedAt: date)
        #expect(f1.lastPathComponent == base)
        #expect(f2.lastPathComponent == "\(base)-2")
        #expect(f3.lastPathComponent == "\(base)-3")
    }

    @Test func timestampSlugUsesOnlyTimestamp() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let ts = Slug.timestamp(date)
        let folder = try RunFolder.create(in: tmp.url, slug: ts, startedAt: date)
        #expect(folder.lastPathComponent == ts)
    }

    @Test func slugWithSlashDoesNotNest() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let folder = try RunFolder.create(in: tmp.url, slug: "../x/y", startedAt: date)
        #expect(folder.deletingLastPathComponent().standardizedFileURL.path == tmp.url.standardizedFileURL.path)
        #expect(!folder.lastPathComponent.contains("/"))
    }

    @Test func concurrentCreationNeverCollides() async throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.url
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let n = 40
        let paths = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<n {
                group.addTask {
                    try? RunFolder.create(in: out, slug: "same", startedAt: date).lastPathComponent
                }
            }
            var result: [String?] = []
            for await p in group { result.append(p) }
            return result
        }
        let names = paths.compactMap { $0 }
        #expect(names.count == n)
        #expect(Set(names).count == n)
        let base = Slug.folderName(slug: "same", startedAt: date)
        let expected = Set([base] + (2...n).map { "\(base)-\($0)" })
        #expect(Set(names) == expected)
    }

    @Test func failsWhenOutputDirectoryIsAFile() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let file = tmp.url.appendingPathComponent("file")
        try Data("x".utf8).write(to: file)
        #expect(throws: (any Error).self) {
            try RunFolder.create(in: file, slug: "a", startedAt: Date())
        }
    }

    @Test func recordRoundTripWithFractionalSeconds() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        var record = qMakeJob(slug: "kina", count: 2, referenceImages: ["/Users/a/ref 1.png"],
                              createdAt: Date(timeIntervalSince1970: 1_793_000_000.25))
        record.status = .done
        record.startedAt = Date(timeIntervalSince1970: 1_793_000_001.5)
        record.finishedAt = Date(timeIntervalSince1970: 1_793_000_061.123)
        record.fullPrompt = "全文\n2 行目"
        record.command = ["/x/codex", "exec", "--", "p"]
        record.commandLine = "/x/codex exec -- p"
        record.exitCode = 0
        record.outputDir = tmp.url.path
        record.images = [tmp.url.appendingPathComponent("kina-01.png").path]
        record.lastMessage = "kina-01.png"
        record.codexThreadId = "thread-1"

        try RunFolder.writeRecord(record, to: tmp.url)
        let text = RunFolder.readText(tmp.url.appendingPathComponent(RunFolder.recordFileName))
        #expect(text.contains("\"createdAt\" : \"20"))
        #expect(text.contains(".250Z\""))
        #expect(text.contains(".500Z\""))
        #expect(!text.contains("\\/"), "スラッシュはエスケープしない")
        #expect(text.contains("\n  \""), "整形済み")
        // キー順が固定（sortedKeys）
        let aspectPos = try #require(text.range(of: "\"aspect\""))
        let statusPos = try #require(text.range(of: "\"status\""))
        #expect(aspectPos.lowerBound < statusPos.lowerBound)

        let loaded = try RunFolder.readRecord(from: tmp.url)
        #expect(abs(loaded.createdAt.timeIntervalSince(record.createdAt)) < 0.001)
        #expect(abs(try #require(loaded.startedAt).timeIntervalSince(try #require(record.startedAt))) < 0.001)
        #expect(abs(try #require(loaded.finishedAt).timeIntervalSince(try #require(record.finishedAt))) < 0.001)
        var normalized = loaded
        normalized.createdAt = record.createdAt
        normalized.startedAt = record.startedAt
        normalized.finishedAt = record.finishedAt
        #expect(normalized == record)
    }

    @Test func decoderAcceptsOtherDateForms() throws {
        let id = UUID()
        let json = """
        [
          {"id": "\(id.uuidString)", "createdAt": "2026-10-24T06:30:12Z", "startedAt": "2026-10-24T15:30:12.500+09:00", "finishedAt": 783000000}
        ]
        """
        let records = try RunFolder.makeDecoder().decode([JobRecord].self, from: Data(json.utf8))
        let r = try #require(records.first)
        #expect(r.id == id)
        #expect(r.createdAt == Date(timeIntervalSince1970: 1_792_823_412))
        let started = try #require(r.startedAt)
        #expect(abs(started.timeIntervalSince1970 - 1_792_823_412.5) < 0.001)
        #expect(r.finishedAt == Date(timeIntervalSinceReferenceDate: 783_000_000))
    }

    @Test func readLogsReturnsContentsOrEmpty() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let empty = RunFolder.readLogs(folder: tmp.url)
        #expect(empty.stdout.isEmpty && empty.stderr.isEmpty)
        try Data("{\"type\":\"a\"}\n".utf8).write(to: tmp.url.appendingPathComponent(RunFolder.stdoutFileName))
        try (Data("bad ".utf8) + Data([0xFF, 0xFE]) + Data(" bytes".utf8))
            .write(to: tmp.url.appendingPathComponent(RunFolder.stderrFileName))
        let logs = RunFolder.readLogs(folder: tmp.url)
        #expect(logs.stdout == "{\"type\":\"a\"}\n")
        #expect(logs.stderr.hasPrefix("bad "))
        #expect(logs.stderr.hasSuffix(" bytes"))
    }

    @Test func deleteRecordFilesKeepsImages() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let folder = try qWriteRunFolder(in: tmp.url, name: "run1", record: qFinishedRecord(slug: "a", startedAt: Date()),
                                         images: ["a-01.png", "a-02.png"])
        try Data("memo".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try RunFolder.deleteRecordFiles(folder: folder)
        let rest = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(rest == ["a-01.png", "a-02.png", "notes.txt"])
    }

    @Test func deleteRecordFilesRemovesEmptyFolder() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let folder = try qWriteRunFolder(in: tmp.url, name: "run1", record: qFinishedRecord(slug: "a", startedAt: Date()))
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        try RunFolder.deleteRecordFiles(folder: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        // 無いフォルダを消しても失敗しない。
        try RunFolder.deleteRecordFiles(folder: folder)
    }
}

// MARK: - QueueStore

@Suite("QueueStore")
struct QueueStoreTests {
    @Test func missingFileLoadsEmpty() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let store = QueueStore(fileURL: tmp.url.appendingPathComponent("none/queue.json"))
        #expect(store.load().isEmpty)
    }

    @Test func saveCreatesParentAndRoundTrips() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let store = QueueStore(fileURL: tmp.url.appendingPathComponent("deep/dir/queue.json"))
        let jobs = [qMakeJob(slug: "a"), qMakeJob(slug: "b", count: 4, referenceImages: ["/r.png"])]
        store.save(jobs)
        let loaded = store.load()
        #expect(loaded.map(\.id) == jobs.map(\.id))
        #expect(loaded.map(\.slug) == ["a", "b"])
        #expect(loaded[1].count == 4)
        #expect(loaded[1].referenceImages == ["/r.png"])
        store.save([])
        #expect(store.load().isEmpty)
    }

    @Test func brokenElementsAreSkipped() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("queue.json")
        let good = qMakeJob(slug: "good")
        let goodJSON = String(decoding: try RunFolder.makeEncoder().encode(good), as: UTF8.self)
        let text = "[\(goodJSON), {\"slug\": \"no-id\"}, 42, {\"id\": \"not-a-uuid\"}]"
        try Data(text.utf8).write(to: url)
        let loaded = QueueStore(fileURL: url).load()
        #expect(loaded.map(\.id) == [good.id])
    }

    @Test func garbageFileLoadsEmpty() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("queue.json")
        try Data("not json".utf8).write(to: url)
        #expect(QueueStore(fileURL: url).load().isEmpty)
    }

    @Test func saveFailureDoesNotCrash() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let blocker = tmp.url.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        // 親が通常ファイルなので書けない。落ちなければよい。
        QueueStore(fileURL: blocker.appendingPathComponent("queue.json")).save([qMakeJob(slug: "a")])
    }
}

// MARK: - HistoryStore

@Suite("HistoryStore")
struct HistoryStoreTests {
    private func readIndex(_ url: URL) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
    }

    @Test func rebuildsHistoryByScanningWithoutIndex() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.sub("out")
        let indexURL = tmp.url.appendingPathComponent("support/history.json")
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        let old = try qWriteRunFolder(in: out, name: "old", record: qFinishedRecord(slug: "old", startedAt: t0), images: ["old-01.png"])
        let new = try qWriteRunFolder(in: out, name: "new", record: qFinishedRecord(slug: "new", startedAt: t0 + 100))
        let mid = try qWriteRunFolder(in: out, name: "mid", record: qFinishedRecord(slug: "mid", startedAt: t0 + 50, status: .failed))
        // run.json の無いフォルダ・通常ファイルは無視する。
        try FileManager.default.createDirectory(at: out.appendingPathComponent("not-a-run"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: out.appendingPathComponent("loose.png"))

        let store = HistoryStore(indexURL: indexURL)
        let records = store.loadAll(outputDirectory: out)
        #expect(records.map(\.slug) == ["new", "mid", "old"])
        #expect(records.map(\.outputDir) == [new.path, mid.path, old.path])
        #expect(records[2].images == [old.appendingPathComponent("old-01.png").path])
        // 索引ができている（新しい順）。
        #expect(try readIndex(indexURL) == [new.path, mid.path, old.path])
    }

    @Test func staleRunningBecomesCancelledWithoutRewriting() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.sub("out")
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        let folder = try qWriteRunFolder(in: out, name: "crash", record: qFinishedRecord(slug: "crash", startedAt: t0, status: .running))
        var queuedRecord = qFinishedRecord(slug: "q", startedAt: t0 - 10, status: .queued)
        queuedRecord.errorSummary = "前の要約"
        try qWriteRunFolder(in: out, name: "q", record: queuedRecord)

        let records = HistoryStore(indexURL: tmp.url.appendingPathComponent("h.json")).loadAll(outputDirectory: out)
        #expect(records.count == 2)
        #expect(records[0].status == .cancelled)
        #expect(records[0].errorSummary == HistoryStore.interruptedSummary)
        #expect(records[1].status == .cancelled)
        #expect(records[1].errorSummary == "前の要約")
        // ファイルはそのまま。
        #expect(try RunFolder.readRecord(from: folder).status == .running)
    }

    @Test func fixesMovedFolderPaths() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.sub("out")
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        let folder = out.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try qPNGData().write(to: folder.appendingPathComponent("m-01.png"))
        var r = qFinishedRecord(slug: "m", startedAt: t0)
        r.outputDir = "/somewhere/else/moved"
        r.images = ["/somewhere/else/moved/m-01.png", "/gone/elsewhere.png"]
        try RunFolder.writeRecord(r, to: folder)

        let records = HistoryStore(indexURL: tmp.url.appendingPathComponent("h.json")).loadAll(outputDirectory: out)
        let loaded = try #require(records.first)
        #expect(loaded.outputDir == folder.path)
        #expect(loaded.images == [folder.appendingPathComponent("m-01.png").path, "/gone/elsewhere.png"])
    }

    @Test func dedupesByIDPreferringOutputDirectory() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.sub("out")
        let elsewhere = tmp.sub("elsewhere")
        let indexURL = tmp.url.appendingPathComponent("h.json")
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        let id = UUID()
        let outside = try qWriteRunFolder(in: elsewhere, name: "copy", record: qFinishedRecord(slug: "dup", startedAt: t0 + 5, id: id))
        let inside = try qWriteRunFolder(in: out, name: "orig", record: qFinishedRecord(slug: "dup", startedAt: t0, id: id))
        let other = try qWriteRunFolder(in: elsewhere, name: "other", record: qFinishedRecord(slug: "other", startedAt: t0 - 100))
        let store = HistoryStore(indexURL: indexURL)
        store.register(try RunFolder.readRecord(from: outside))
        store.register(try RunFolder.readRecord(from: other))

        let records = store.loadAll(outputDirectory: out)
        #expect(records.map(\.slug) == ["dup", "other"])
        #expect(records[0].outputDir == inside.path)
        #expect(records[1].outputDir == other.path)
        #expect(try readIndex(indexURL) == [inside.path, other.path])
    }

    @Test func dedupeWithinSameLocationPrefersNewest() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.sub("out")
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        let id = UUID()
        try qWriteRunFolder(in: out, name: "a", record: qFinishedRecord(slug: "older", startedAt: t0, id: id))
        let newer = try qWriteRunFolder(in: out, name: "b", record: qFinishedRecord(slug: "newer", startedAt: t0 + 10, id: id))
        let records = HistoryStore(indexURL: tmp.url.appendingPathComponent("h.json")).loadAll(outputDirectory: out)
        #expect(records.count == 1)
        #expect(records.first?.outputDir == newer.path)
    }

    @Test func missingOutputDirectoryUsesIndexOnly() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let elsewhere = tmp.sub("elsewhere")
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        let a = try qWriteRunFolder(in: elsewhere, name: "a", record: qFinishedRecord(slug: "a", startedAt: t0))
        let gone = elsewhere.appendingPathComponent("gone").path
        let indexURL = tmp.url.appendingPathComponent("h.json")
        try JSONEncoder().encode([gone, a.path]).write(to: indexURL)

        let store = HistoryStore(indexURL: indexURL)
        let records = store.loadAll(outputDirectory: tmp.sub("does-not-exist"))
        #expect(records.map(\.slug) == ["a"])
        // 消えたフォルダは索引から落ちる。
        #expect(try readIndex(indexURL) == [a.path])
    }

    @Test func registerAddsToFrontOnce() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let indexURL = tmp.url.appendingPathComponent("support/h.json")
        let store = HistoryStore(indexURL: indexURL)
        var r1 = qMakeJob(slug: "a")
        r1.outputDir = "/x/run-a"
        var r2 = qMakeJob(slug: "b")
        r2.outputDir = "/x/run-b"
        var empty = qMakeJob(slug: "c")
        empty.outputDir = ""
        store.register(r1)
        store.register(r2)
        store.register(r1)
        store.register(empty)
        #expect(try readIndex(indexURL) == ["/x/run-b", "/x/run-a"])
    }

    @Test func deleteRemovesRecordButKeepsImages() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.sub("out")
        let indexURL = tmp.url.appendingPathComponent("h.json")
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        let keep = try qWriteRunFolder(in: out, name: "keep", record: qFinishedRecord(slug: "keep", startedAt: t0))
        let target = try qWriteRunFolder(in: out, name: "target", record: qFinishedRecord(slug: "target", startedAt: t0 + 1),
                                         images: ["target-01.png"])
        let store = HistoryStore(indexURL: indexURL)
        let records = store.loadAll(outputDirectory: out)
        #expect(records.count == 2)
        let victim = try #require(records.first { $0.slug == "target" })

        try store.delete(victim)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["target-01.png"])
        #expect(try readIndex(indexURL) == [keep.path])
        let after = store.loadAll(outputDirectory: out)
        #expect(after.map(\.slug) == ["keep"])
    }

    @Test func deleteRemovesEmptyFolder() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.sub("out")
        let folder = try qWriteRunFolder(in: out, name: "f", record: qFinishedRecord(slug: "f", startedAt: Date()))
        let store = HistoryStore(indexURL: tmp.url.appendingPathComponent("h.json"))
        let record = try #require(store.loadAll(outputDirectory: out).first)
        try store.delete(record)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(store.loadAll(outputDirectory: out).isEmpty)
    }

    @Test func unreadableRunJSONIsSkippedButKeptInIndex() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.sub("out")
        let good = try qWriteRunFolder(in: out, name: "good", record: qFinishedRecord(slug: "good", startedAt: Date()))
        let broken = out.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: broken.appendingPathComponent(RunFolder.recordFileName))
        let indexURL = tmp.url.appendingPathComponent("h.json")
        let records = HistoryStore(indexURL: indexURL).loadAll(outputDirectory: out)
        #expect(records.map(\.slug) == ["good"])
        #expect(try readIndex(indexURL) == [good.path, broken.path])
    }

    // MARK: 実行中のジョブを守る

    @Test func folderInUseIsNeitherListedNorDeleted() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.sub("out")
        let indexURL = tmp.url.appendingPathComponent("h.json")
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        // JobExecutor が実行中に置くのと同じ形（run.json は running、画像はまだ無い）。
        let live = try qWriteRunFolder(in: out, name: "live", record: qFinishedRecord(slug: "live", startedAt: t0, status: .running))
        let done = try qWriteRunFolder(in: out, name: "done", record: qFinishedRecord(slug: "done", startedAt: t0 - 10))
        let store = HistoryStore(indexURL: indexURL)
        RunFolder.beginUse(live)
        var inUse = true
        defer { if inUse { RunFolder.endUse(live) } }

        // 実行中のフォルダは履歴に出さない（中断扱いにもしない）。索引からも落とさない。
        let records = store.loadAll(outputDirectory: out)
        #expect(records.map(\.slug) == ["done"])
        #expect(Set(try readIndex(indexURL)) == Set([done.path, live.path]))

        // 削除を頼まれても消さない（中断扱いを許しても）。
        let liveRecord = try RunFolder.readRecord(from: live)
        for allowing in [false, true] {
            #expect(throws: RunFolderError.inUse(live.path)) {
                try store.delete(liveRecord, allowingInterrupted: allowing)
            }
        }
        #expect(throws: RunFolderError.inUse(live.path)) {
            try RunFolder.deleteRecordFiles(folder: live)
        }
        for name in RunFolder.recordFileNames {
            #expect(FileManager.default.fileExists(atPath: live.appendingPathComponent(name).path), "\(name)")
        }
        #expect(Set(try readIndex(indexURL)) == Set([done.path, live.path]))

        // 終わって印が外れたら、ふつうに読める。
        var finished = liveRecord
        finished.status = .done
        try RunFolder.writeRecord(finished, to: live)
        RunFolder.endUse(live)
        inUse = false
        #expect(store.loadAll(outputDirectory: out).map(\.slug) == ["live", "done"])
    }

    @Test func staleRunningFolderIsDeletedOnlyWhenAllowed() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.sub("out")
        let indexURL = tmp.url.appendingPathComponent("h.json")
        let folder = try qWriteRunFolder(in: out, name: "crash", record: qFinishedRecord(slug: "crash", startedAt: Date(), status: .running))
        let store = HistoryStore(indexURL: indexURL)
        let record = try #require(store.loadAll(outputDirectory: out).first)
        #expect(record.status == .cancelled)

        // run.json が running のままなので、既定では消さない（別に起動しているアプリが使っているかもしれない）。
        #expect(throws: HistoryStoreError.stillRunning(folder.path)) {
            try store.delete(record)
        }
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(RunFolder.promptFileName).path))
        #expect(try readIndex(indexURL) == [folder.path])

        // 呼び出し側が「自分のキューにはない」と確かめたら消せる。
        try store.delete(record, allowingInterrupted: true)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(try readIndex(indexURL).isEmpty)
    }

    @Test func excludedIDsAreSkippedButKeptInIndex() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.sub("out")
        let indexURL = tmp.url.appendingPathComponent("h.json")
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        let running = qFinishedRecord(slug: "running", startedAt: t0, status: .running)
        let runningFolder = try qWriteRunFolder(in: out, name: "running", record: running)
        let done = try qWriteRunFolder(in: out, name: "done", record: qFinishedRecord(slug: "done", startedAt: t0 - 10))
        let store = HistoryStore(indexURL: indexURL)
        let records = store.loadAll(outputDirectory: out, excluding: [running.id])
        #expect(records.map(\.slug) == ["done"])
        #expect(Set(try readIndex(indexURL)) == Set([done.path, runningFolder.path]))
        // 除外しなければ、前回の異常終了として出る。
        #expect(store.loadAll(outputDirectory: out).map(\.status) == [.cancelled, .done])
    }

    // MARK: 自分の作ったものだけを消す

    @Test func deleteRefusesRunJSONWrittenBySomethingElse() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.sub("out")
        let foreign = out.appendingPathComponent("my-notes", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data(#"{"id":"\#(UUID().uuidString)","name":"other tool"}"#.utf8).write(to: foreign.appendingPathComponent(RunFolder.recordFileName))
        try Data("ユーザーのメモ".utf8).write(to: foreign.appendingPathComponent(RunFolder.promptFileName))
        let store = HistoryStore(indexURL: tmp.url.appendingPathComponent("h.json"))
        // このアプリが書いたと確かめられない run.json は履歴に出さない（出すと消せない行が残る）。
        #expect(store.loadAll(outputDirectory: out).isEmpty)

        // 古い索引などから、その記録を消そうとしても断る。
        var record = try RunFolder.readRecord(from: foreign)
        record.outputDir = foreign.path
        #expect(throws: HistoryStoreError.notOurRecord(foreign.path)) {
            try store.delete(record, allowingInterrupted: true)
        }
        let rest = try FileManager.default.contentsOfDirectory(atPath: foreign.path).sorted()
        #expect(rest == [RunFolder.promptFileName, RunFolder.recordFileName])
    }

    @Test func deleteRefusesWhenRunJSONNowBelongsToAnotherJob() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.sub("out")
        let folder = try qWriteRunFolder(in: out, name: "f", record: qFinishedRecord(slug: "f", startedAt: Date()))
        let store = HistoryStore(indexURL: tmp.url.appendingPathComponent("h.json"))
        let record = try #require(store.loadAll(outputDirectory: out).first)
        // 読み込んだあとで、フォルダの中身が別のジョブに入れ替わった。
        var other = try RunFolder.readRecord(from: folder)
        other.id = UUID()
        try RunFolder.writeRecord(other, to: folder)

        #expect(throws: HistoryStoreError.recordMismatch(folder.path)) {
            try store.delete(record)
        }
        #expect(try RunFolder.readRecord(from: folder).id == other.id)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(RunFolder.stdoutFileName).path))
    }

    @Test func deleteRefusesUnreadableRunJSON() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.sub("out")
        let folder = try qWriteRunFolder(in: out, name: "f", record: qFinishedRecord(slug: "f", startedAt: Date()))
        let store = HistoryStore(indexURL: tmp.url.appendingPathComponent("h.json"))
        let record = try #require(store.loadAll(outputDirectory: out).first)
        try Data("{ broken".utf8).write(to: folder.appendingPathComponent(RunFolder.recordFileName))
        #expect(throws: HistoryStoreError.notOurRecord(folder.path)) {
            try store.delete(record)
        }
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(RunFolder.promptFileName).path))
    }

    @Test func deleteNeverFollowsASymlinkedFolder() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.sub("out")
        let elsewhere = tmp.sub("elsewhere")
        let real = try qWriteRunFolder(in: elsewhere, name: "real", record: qFinishedRecord(slug: "real", startedAt: Date()))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let link = out.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let store = HistoryStore(indexURL: tmp.url.appendingPathComponent("h.json"))
        let record = try #require(store.loadAll(outputDirectory: out).first)
        #expect(record.outputDir == link.path)

        #expect(throws: RunFolderError.symlinkedFolder(link.path)) {
            try store.delete(record)
        }
        for name in RunFolder.recordFileNames {
            #expect(FileManager.default.fileExists(atPath: real.appendingPathComponent(name).path), "\(name)")
        }
    }

    @Test func deleteRecordFilesUnlinksLinksAndKeepsDirectories() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let folder = try qWriteRunFolder(in: tmp.url, name: "run", record: qFinishedRecord(slug: "a", startedAt: Date()), extraFiles: false)
        // prompt.txt がフォルダの外を指すリンク、stdout.jsonl という名前のディレクトリ。
        let outside = tmp.url.appendingPathComponent("outside.txt")
        try Data("外のファイル".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(RunFolder.promptFileName), withDestinationURL: outside)
        let dir = folder.appendingPathComponent(RunFolder.stdoutFileName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("中身".utf8).write(to: dir.appendingPathComponent("keep.txt"))

        try RunFolder.deleteRecordFiles(folder: folder)
        #expect(RunFolder.readText(outside) == "外のファイル")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [RunFolder.stdoutFileName])
        #expect(RunFolder.readText(dir.appendingPathComponent("keep.txt")) == "中身")
    }

    @Test func deleteWithoutRunJSONOnlyDropsTheIndexEntry() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.sub("out")
        let indexURL = tmp.url.appendingPathComponent("h.json")
        let folder = try qWriteRunFolder(in: out, name: "f", record: qFinishedRecord(slug: "f", startedAt: Date()))
        let store = HistoryStore(indexURL: indexURL)
        let record = try #require(store.loadAll(outputDirectory: out).first)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(RunFolder.recordFileName))

        try store.delete(record)
        #expect(try readIndex(indexURL).isEmpty)
        // 持ち主を確かめられないので、残りのファイルには触らない。
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(RunFolder.promptFileName).path))
    }

    // MARK: 失敗したときの約束

    @Test func deleteFailureThrowsAndKeepsIndex() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.sub("out")
        let indexURL = tmp.url.appendingPathComponent("h.json")
        let folder = try qWriteRunFolder(in: out, name: "locked", record: qFinishedRecord(slug: "locked", startedAt: Date()))
        let store = HistoryStore(indexURL: indexURL)
        let record = try #require(store.loadAll(outputDirectory: out).first)
        #expect(try readIndex(indexURL) == [folder.path])

        // フォルダを書き込み禁止にすると、中のファイルを消せない。
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        #expect(throws: (any Error).self) {
            try store.delete(record)
        }
        #expect(try readIndex(indexURL) == [folder.path])
        for name in RunFolder.recordFileNames {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "\(name)")
        }
        #expect(store.loadAll(outputDirectory: out).map(\.id) == [record.id])
    }

    // MARK: 見えないボリューム

    @Test func keepsIndexEntriesWhoseVolumeIsNotReachable() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.sub("out")
        let indexURL = tmp.url.appendingPathComponent("h.json")
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        // 外付けドライブ上の出力ディレクトリ（あとで外す）。
        let volumeOut = tmp.url.appendingPathComponent("Volumes/SSD/CodexImages", isDirectory: true)
        let onVolume = try qWriteRunFolder(in: volumeOut, name: "on-ssd", record: qFinishedRecord(slug: "ssd", startedAt: t0))
        // 親フォルダは見えるが、フォルダ自体が消されたもの。
        let deleted = try qWriteRunFolder(in: out, name: "deleted", record: qFinishedRecord(slug: "deleted", startedAt: t0 + 1))
        let store = HistoryStore(indexURL: indexURL)
        store.register(try RunFolder.readRecord(from: onVolume))
        #expect(Set(store.loadAll(outputDirectory: out).map(\.slug)) == ["ssd", "deleted"])

        // ドライブを外す（ボリュームごと見えなくなる）。消したフォルダも用意する。
        let unplugged = tmp.url.appendingPathComponent("unplugged", isDirectory: true)
        try FileManager.default.moveItem(at: tmp.url.appendingPathComponent("Volumes/SSD"), to: unplugged)
        try FileManager.default.removeItem(at: deleted)
        #expect(store.loadAll(outputDirectory: out).isEmpty)
        #expect(try readIndex(indexURL) == [onVolume.path], "見えないボリュームの記録は索引に残し、消されたものだけ落とす")

        // つなぎ直すと、出力ディレクトリが別のままでも戻ってくる。
        try FileManager.default.moveItem(at: unplugged, to: tmp.url.appendingPathComponent("Volumes/SSD"))
        #expect(store.loadAll(outputDirectory: out).map(\.slug) == ["ssd"])
    }

    // MARK: 出力フォルダを作れなかったジョブ

    @Test func scansFailedRecordsDirectoryWithoutIndex() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let support = tmp.sub("support")
        let indexURL = support.appendingPathComponent("history.json")
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        var failed = qFinishedRecord(slug: "lost", startedAt: t0, status: .failed)
        failed.errorSummary = "出力フォルダを作れませんでした: /Volumes/NoSuchDrive/Images"
        let failedFolder = try qWriteRunFolder(
            in: support.appendingPathComponent(RunFolder.failedRecordsDirectoryName),
            name: "20261025-120000-lost",
            record: failed,
            extraFiles: false
        )
        let store = HistoryStore(indexURL: indexURL)
        #expect(store.failedRecordsDirectory?.standardizedFileURL.path
            == support.appendingPathComponent(RunFolder.failedRecordsDirectoryName).standardizedFileURL.path)
        let records = store.loadAll(outputDirectory: tmp.sub("out"))
        let loaded = try #require(records.first)
        #expect(records.count == 1)
        #expect(loaded.id == failed.id)
        #expect(loaded.prompt == failed.prompt)
        #expect(loaded.outputDir == failedFolder.path)
        #expect(try readIndex(indexURL) == [failedFolder.path])
        // 走査しない設定にもできる。
        let without = HistoryStore(indexURL: tmp.url.appendingPathComponent("other.json"), failedRecordsDirectory: nil)
        #expect(without.loadAll(outputDirectory: tmp.sub("out")).isEmpty)
        // 消せる（フォルダごと無くなる）。
        try store.delete(loaded)
        #expect(!FileManager.default.fileExists(atPath: failedFolder.path))
    }
}
