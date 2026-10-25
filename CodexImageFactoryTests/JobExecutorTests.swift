import Foundation
import Synchronization
import Testing
@testable import CodexImageFactory

// MARK: - ダミーの runner

/// codex の代わり。台本（script）どおりに行を流し、ファイルを書き、終わり方を返す。
final class QMockRunner: CodexRunning {
    typealias Script = @Sendable (CodexInvocation, @escaping @Sendable (CodexStream, String) -> Void) async throws -> ProcessOutcome

    private let script: Script
    private let invocations = Mutex<[CodexInvocation]>([])
    private let concurrency = Mutex<(current: Int, max: Int)>((0, 0))

    init(_ script: @escaping Script) {
        self.script = script
    }

    var recordedInvocations: [CodexInvocation] {
        invocations.withLock { $0 }
    }

    var maxConcurrent: Int {
        concurrency.withLock { $0.max }
    }

    func run(
        _ invocation: CodexInvocation,
        onLine: @escaping @Sendable (CodexStream, String) -> Void
    ) async throws -> ProcessOutcome {
        invocations.withLock { $0.append(invocation) }
        concurrency.withLock { c in
            c.current += 1
            c.max = max(c.max, c.current)
        }
        defer { concurrency.withLock { $0.current -= 1 } }
        return try await script(invocation, onLine)
    }

    /// `-o` で渡された last-message.md の場所。
    static func lastMessageURL(_ invocation: CodexInvocation) -> URL? {
        guard let i = invocation.arguments.firstIndex(of: "-o"), i + 1 < invocation.arguments.count else { return nil }
        return URL(fileURLWithPath: invocation.arguments[i + 1])
    }

    /// 本物の codex と同じく、作業ディレクトリに画像と last-message.md を書く台本。
    static func writingImages(
        _ names: [String],
        lastMessage: String? = nil,
        stdout: [String] = [],
        stderr: [String] = [],
        exitCode: Int32 = 0,
        delay: Duration = .zero
    ) -> Script {
        { invocation, onLine in
            for line in stdout { onLine(.stdout, line) }
            for line in stderr { onLine(.stderr, line) }
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            for (i, name) in names.enumerated() {
                try qPNGData(UInt8(i)).write(to: invocation.workingDirectory.appendingPathComponent(name))
            }
            if let lastMessage, let url = lastMessageURL(invocation) {
                try Data(lastMessage.utf8).write(to: url)
            }
            return ProcessOutcome(exitCode: exitCode)
        }
    }
}

/// JobEvent を比べやすい文字列にする。
private func qDescribe(_ event: JobEvent) -> String {
    switch event {
    case .started: "started"
    case .line(let stream, let text): "\(stream.rawValue):\(text)"
    case .rateLimited(let text): "rateLimited:\(text)"
    }
}

private func qStartedRecord(_ events: [JobEvent]) -> JobRecord? {
    for event in events {
        if case .started(let r) = event { return r }
    }
    return nil
}

/// テスト 1 件分の道具一式。
private struct QExecutorFixture {
    let tmp: QTempDir
    let out: URL
    let codexHome: URL
    let codexPath: String
    let events = QLog<JobEvent>()
    let start: Date?

    init(fixedStart: Date? = nil) throws {
        tmp = try QTempDir()
        out = tmp.sub("out")
        codexHome = tmp.sub("codex-home")
        codexPath = try qMakeFakeCodex(in: tmp.url)
        start = fixedStart
    }

    func executor(_ runner: QMockRunner) -> JobExecutor {
        let fixed = start
        return JobExecutor(
            runner: runner,
            codexHome: codexHome,
            environment: { ["HOME": "/Users/q-test", "PATH": "/usr/bin:/bin"] },
            now: { fixed ?? Date() }
        )
    }

    func settings(codexPath: String? = nil, timeoutSeconds: Int = 600) -> AppSettings {
        qSettings(outputDirectory: out, codexPath: codexPath ?? self.codexPath, timeoutSeconds: timeoutSeconds)
    }

    func run(_ runner: QMockRunner, job: JobRecord, settings: AppSettings? = nil) async -> JobRecord {
        let events = events
        return await executor(runner).execute(job, settings: settings ?? self.settings()) { events.append($0) }
    }
}

// MARK: - JobExecutor

@Suite("JobExecutor")
struct JobExecutorTests {
    @Test func successWritesFolderAndOrdersImages() async throws {
        let fixedStart = Date(timeIntervalSince1970: 1_793_000_000)
        let f = try QExecutorFixture(fixedStart: fixedStart)
        defer { f.tmp.remove() }
        let stdout = [
            #"{"type":"thread.started","thread_id":"thread-abc"}"#,
            #"{"type":"item.completed","item":{"type":"error","message":"under-development features"}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":2}}"#,
        ]
        let stderr = ["Reading additional input from stdin...", "ERROR codex_core::tools::router: collab spawn failed"]
        // 名前順と期待順が違うように書く（extra は last-message にも無い）。
        let runner = QMockRunner(QMockRunner.writingImages(
            ["kina-02.png", "extra.png", "kina-01.png"],
            lastMessage: "kina-01.png\nkina-02.png\n",
            stdout: stdout,
            stderr: stderr
        ))
        let job = qMakeJob(slug: "kina", count: 2)
        let result = await f.run(runner, job: job)

        #expect(result.status == .done)
        #expect(result.errorSummary == nil)
        #expect(result.id == job.id)
        #expect(result.exitCode == 0)
        #expect(result.codexThreadId == "thread-abc")
        #expect(result.lastMessage == "kina-01.png\nkina-02.png")
        #expect(result.startedAt == fixedStart)
        #expect(result.finishedAt != nil)

        let folder = URL(fileURLWithPath: result.outputDir, isDirectory: true)
        #expect(folder.lastPathComponent == Slug.folderName(slug: "kina", startedAt: fixedStart))
        #expect(folder.deletingLastPathComponent().standardizedFileURL.path == f.out.standardizedFileURL.path)
        #expect(result.images == ["kina-01.png", "kina-02.png", "extra.png"].map { folder.appendingPathComponent($0).path })
        #expect(result.images.allSatisfy { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) })

        // コマンド
        let expectedPrompt = PromptBuilder.fullPrompt(for: job, template: AppSettings.defaultInstructionTemplate)
        #expect(result.fullPrompt == expectedPrompt)
        let options = CommandBuilder.Options(codexPath: f.codexPath, workingDirectory: folder.path, prompt: expectedPrompt)
        #expect(result.command == CommandBuilder.command(options))
        #expect(result.commandLine == CommandBuilder.commandLine(options))
        let invocation = try #require(runner.recordedInvocations.first)
        #expect(invocation.executableURL.path == f.codexPath)
        #expect(invocation.arguments == Array(result.command.dropFirst()))
        #expect(invocation.workingDirectory.path == folder.path)
        #expect(invocation.environment["HOME"] == "/Users/q-test")
        #expect(invocation.timeout == 600)

        // フォルダの中身
        let fm = FileManager.default
        for name in [RunFolder.recordFileName, RunFolder.promptFileName, RunFolder.stdoutFileName,
                     RunFolder.stderrFileName, RunFolder.lastMessageFileName] {
            #expect(fm.fileExists(atPath: folder.appendingPathComponent(name).path), "\(name) がある")
        }
        #expect(RunFolder.readText(folder.appendingPathComponent(RunFolder.promptFileName)) == expectedPrompt)
        let logs = RunFolder.readLogs(folder: folder)
        #expect(logs.stdout == stdout.map { $0 + "\n" }.joined())
        #expect(logs.stderr == stderr.map { $0 + "\n" }.joined())
        let saved = try RunFolder.readRecord(from: folder)
        #expect(saved.status == .done)
        #expect(saved.images == result.images)
        #expect(saved.commandLine == result.commandLine)

        // 出来事: started が最初、続いて行がそのままの順で届く。
        let described = f.events.all.map(qDescribe)
        #expect(described.first == "started")
        #expect(described.dropFirst().filter { $0.hasPrefix("stdout:") } == stdout.map { "stdout:" + $0 })
        #expect(described.dropFirst().filter { $0.hasPrefix("stderr:") } == stderr.map { "stderr:" + $0 })
        #expect(!described.contains { $0.hasPrefix("rateLimited") })
        let started = try #require(qStartedRecord(f.events.all))
        #expect(started.status == .running)
        #expect(started.outputDir == folder.path)
        #expect(started.commandLine == result.commandLine)
        #expect(started.fullPrompt == expectedPrompt)
        #expect(started.startedAt == fixedStart)
    }

    @Test func passesModelEffortEphemeralAndReferences() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        let ref = f.tmp.url.appendingPathComponent("ref.png")
        try qPNGData().write(to: ref)
        let runner = QMockRunner(QMockRunner.writingImages(["r-01.png"]))
        var settings = f.settings(timeoutSeconds: 5)
        settings.model = "gpt-test"
        settings.reasoningEffort = .high
        settings.useEphemeral = true
        let result = await f.run(runner, job: qMakeJob(slug: "r", referenceImages: [ref.path]), settings: settings)
        #expect(result.status == .done)
        let args = try #require(runner.recordedInvocations.first).arguments
        #expect(args.contains("--ephemeral"))
        #expect(args.contains("gpt-test"))
        #expect(args.contains("model_reasoning_effort=\"high\""))
        let i = try #require(args.firstIndex(of: "-i"))
        #expect(args[i + 1] == ref.path)
        #expect(args[args.count - 2] == "--")
        // タイムアウトは下限に丸める。
        #expect(try #require(runner.recordedInvocations.first).timeout == TimeInterval(AppSettings.minimumTimeoutSeconds))
    }

    @Test func nonZeroExitFailsWithStderrTail() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        let stderr = ["Reading additional input from stdin..."] + (1...15).map { String(format: "stderr-%02d", $0) }
        let stdout = [#"{"type":"turn.failed","error":{"message":"モデルが失敗しました"}}"#]
        let runner = QMockRunner(QMockRunner.writingImages([], stdout: stdout, stderr: stderr, exitCode: 1))
        let result = await f.run(runner, job: qMakeJob(slug: "x"))
        #expect(result.status == .failed)
        #expect(result.exitCode == 1)
        let summary = try #require(result.errorSummary)
        #expect(summary.contains("終了コード 1"))
        #expect(summary.contains("モデルが失敗しました"))
        #expect(summary.contains("stderr-15"))
        #expect(summary.contains("stderr-06"))
        #expect(!summary.contains("stderr-05"))
        #expect(!summary.contains("Reading additional input"))
        #expect(summary.count <= JobExecutor.maxErrorSummaryLength)
        #expect(try RunFolder.readRecord(from: URL(fileURLWithPath: result.outputDir)).status == .failed)
    }

    @Test func nonZeroExitWithImagesStillFails() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        let runner = QMockRunner(QMockRunner.writingImages(["x-01.png"], exitCode: 2))
        let result = await f.run(runner, job: qMakeJob(slug: "x"))
        #expect(result.status == .failed)
        #expect(result.images.count == 1)
    }

    @Test func errorSummaryIsCapped() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        let long = String(repeating: "あ", count: 5000)
        let stdout = [#"{"type":"error","message":"\#(long)"}"#]
        let stderr = (1...40).map { "\($0) " + String(repeating: "x", count: 1000) }
        let runner = QMockRunner(QMockRunner.writingImages([], stdout: stdout, stderr: stderr, exitCode: 1))
        let result = await f.run(runner, job: qMakeJob(slug: "x"))
        #expect(try #require(result.errorSummary).count <= JobExecutor.maxErrorSummaryLength)
    }

    @Test func exitZeroWithoutImagesFails() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        let runner = QMockRunner(QMockRunner.writingImages([], lastMessage: "できませんでした", stderr: ["warn"]))
        let result = await f.run(runner, job: qMakeJob(slug: "x"))
        #expect(result.status == .failed)
        #expect(result.exitCode == 0)
        #expect(result.images.isEmpty)
        let summary = try #require(result.errorSummary)
        #expect(summary.hasPrefix(JobExecutor.noImagesSummary))
        #expect(summary.contains("warn"))
        #expect(result.lastMessage == "できませんでした")
    }

    @Test func copiesFromGeneratedImagesWhenModelDidNotCopy() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        let home = f.codexHome
        let runner = QMockRunner { _, onLine in
            onLine(.stdout, #"{"type":"thread.started","thread_id":"thread-xyz"}"#)
            let dir = home.appendingPathComponent("generated_images/thread-xyz", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try qPNGData(7).write(to: dir.appendingPathComponent("exec-1111.png"))
            onLine(.stdout, #"{"type":"turn.completed"}"#)
            return ProcessOutcome(exitCode: 0)
        }
        let result = await f.run(runner, job: qMakeJob(slug: "gen"))
        #expect(result.status == .done)
        #expect(result.codexThreadId == "thread-xyz")
        let folder = URL(fileURLWithPath: result.outputDir)
        let copied = folder.appendingPathComponent("gen-01.png")
        #expect(result.images == [copied.path])
        #expect(try Data(contentsOf: copied) == qPNGData(7))
        // 元のファイルは残す。
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("generated_images/thread-xyz/exec-1111.png").path))
    }

    @Test func savesBase64ImagesFromJSONL() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        let png = qPNGData(3, size: 400)
        let b64 = png.base64EncodedString()
        let line = #"{"type":"item.completed","item":{"type":"image_generation","result":"\#(b64)"}}"#
        let runner = QMockRunner { _, onLine in
            onLine(.stdout, line)
            onLine(.stdout, line) // 同じ画像が 2 回出ても 1 枚
            return ProcessOutcome(exitCode: 0)
        }
        let result = await f.run(runner, job: qMakeJob(slug: "b64"))
        #expect(result.status == .done)
        let folder = URL(fileURLWithPath: result.outputDir)
        #expect(result.images == [folder.appendingPathComponent("b64-01.png").path])
        #expect(try Data(contentsOf: folder.appendingPathComponent("b64-01.png")) == png)
    }

    @Test func rateLimitIsReportedOnce() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        let runner = QMockRunner(QMockRunner.writingImages(
            [],
            stdout: [#"{"type":"error","message":"You've hit your usage limit"}"#,
                     #"{"type":"item.completed","item":{"type":"command_execution","aggregated_output":"rate limit"}}"#],
            stderr: ["Error: 429 Too Many Requests", "Error: 429 Too Many Requests"],
            exitCode: 1
        ))
        let result = await f.run(runner, job: qMakeJob(slug: "rl"))
        #expect(result.status == .failed)
        let rate = f.events.all.map(qDescribe).filter { $0.hasPrefix("rateLimited:") }
        #expect(rate.count == 1)
        #expect(rate.first?.contains("usage limit") == true)
    }

    @Test func ignoresRateLimitWordsInCommandOutput() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        let runner = QMockRunner(QMockRunner.writingImages(
            ["ok-01.png"],
            stdout: [#"{"type":"item.completed","item":{"type":"command_execution","aggregated_output":"rate limit 429"}}"#]
        ))
        let result = await f.run(runner, job: qMakeJob(slug: "ok"))
        #expect(result.status == .done)
        #expect(!f.events.all.map(qDescribe).contains { $0.hasPrefix("rateLimited") })
    }

    @Test func cancellationReturnsCancelled() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        let runner = QMockRunner { _, onLine in
            onLine(.stdout, #"{"type":"thread.started","thread_id":"t-cancel"}"#)
            // 本物の runner と同じく、キャンセルされたら止めて cancelled を返す。
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return ProcessOutcome(exitCode: 2, terminatedBySignal: true, cancelled: true)
        }
        let executor = f.executor(runner)
        let settings = f.settings()
        let events = f.events
        let task = Task { await executor.execute(qMakeJob(slug: "c"), settings: settings) { events.append($0) } }
        let invoked = await qWaitUntil { !runner.recordedInvocations.isEmpty }
        #expect(invoked)
        task.cancel()
        let result = await task.value
        #expect(result.status == .cancelled)
        #expect(result.errorSummary == JobExecutor.cancelledSummary)
        #expect(result.images.isEmpty)
        let saved = try RunFolder.readRecord(from: URL(fileURLWithPath: result.outputDir))
        #expect(saved.status == .cancelled)
    }

    @Test func cancelledBeforeStartDoesNotRun() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        let runner = QMockRunner(QMockRunner.writingImages(["c-01.png"]))
        let executor = f.executor(runner)
        let settings = f.settings()
        let task = Task {
            // キャンセルされるまで待ってから実行する。
            try? await Task.sleep(for: .seconds(30))
            return await executor.execute(qMakeJob(slug: "c"), settings: settings) { _ in }
        }
        task.cancel()
        let result = await task.value
        #expect(result.status == .cancelled)
        #expect(runner.recordedInvocations.isEmpty)
    }

    @Test func timeoutFailsWithMessage() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        let runner = QMockRunner { _, onLine in
            onLine(.stderr, "still working")
            return ProcessOutcome(exitCode: 2, terminatedBySignal: true, timedOut: true)
        }
        let result = await f.run(runner, job: qMakeJob(slug: "t"), settings: f.settings(timeoutSeconds: 45))
        #expect(result.status == .failed)
        let summary = try #require(result.errorSummary)
        #expect(summary.hasPrefix("タイムアウト（45 秒）のため中止しました"))
        #expect(summary.contains("still working"))
        #expect(try #require(runner.recordedInvocations.first).timeout == 45)
    }

    @Test func missingCodexPathFailsBeforeLaunch() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        let runner = QMockRunner(QMockRunner.writingImages(["x-01.png"]))
        let result = await f.run(runner, job: qMakeJob(slug: "x"), settings: f.settings(codexPath: "  "))
        #expect(result.status == .failed)
        #expect(result.errorSummary == JobExecutor.missingCodexPathSummary)
        #expect(runner.recordedInvocations.isEmpty)
        let folder = URL(fileURLWithPath: result.outputDir)
        #expect(try RunFolder.readRecord(from: folder).status == .failed)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(RunFolder.promptFileName).path))
        #expect(f.events.all.map(qDescribe) == ["started"])
    }

    @Test func codexNotFoundFails() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        let runner = QMockRunner(QMockRunner.writingImages(["x-01.png"]))
        let missing = f.tmp.url.appendingPathComponent("no-such-codex").path
        let result = await f.run(runner, job: qMakeJob(slug: "x"), settings: f.settings(codexPath: missing))
        #expect(result.status == .failed)
        #expect(result.errorSummary == "codex が見つかりません: \(missing)")
        #expect(runner.recordedInvocations.isEmpty)
        #expect(try RunFolder.readRecord(from: URL(fileURLWithPath: result.outputDir)).status == .failed)

        // ディレクトリや実行権限の無いファイルも同じ扱い。
        let plain = f.tmp.url.appendingPathComponent("plain")
        try Data("x".utf8).write(to: plain)
        let r2 = await f.run(runner, job: qMakeJob(slug: "y"), settings: f.settings(codexPath: plain.path))
        #expect(r2.errorSummary == "codex が見つかりません: \(plain.path)")
        let r3 = await f.run(runner, job: qMakeJob(slug: "z"), settings: f.settings(codexPath: f.tmp.url.path))
        #expect(r3.status == .failed)
        #expect(runner.recordedInvocations.isEmpty)
    }

    @Test func missingReferenceImageFails() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        let present = f.tmp.url.appendingPathComponent("present.png")
        try qPNGData().write(to: present)
        let missing = f.tmp.url.appendingPathComponent("missing.png").path
        let runner = QMockRunner(QMockRunner.writingImages(["x-01.png"]))
        let result = await f.run(runner, job: qMakeJob(slug: "x", referenceImages: [present.path, missing]))
        #expect(result.status == .failed)
        let summary = try #require(result.errorSummary)
        #expect(summary.contains("参照画像が見つかりません"))
        #expect(summary.contains(missing))
        #expect(!summary.contains(present.path))
        #expect(runner.recordedInvocations.isEmpty)
        #expect(try RunFolder.readRecord(from: URL(fileURLWithPath: result.outputDir)).status == .failed)
    }

    @Test func launchFailureFails() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        let runner = QMockRunner { _, _ in throw CodexRunnerError.launchFailed("boom") }
        let result = await f.run(runner, job: qMakeJob(slug: "x"))
        #expect(result.status == .failed)
        #expect(result.exitCode == nil)
        #expect(try #require(result.errorSummary).contains("codex を起動できませんでした: boom"))
        #expect(try RunFolder.readRecord(from: URL(fileURLWithPath: result.outputDir)).status == .failed)
    }

    @Test func outputFolderFailureReturnsFailedWithoutFolder() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        let blocker = f.tmp.url.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let runner = QMockRunner(QMockRunner.writingImages(["x-01.png"]))
        let settings = qSettings(outputDirectory: blocker, codexPath: f.codexPath)
        let result = await f.run(runner, job: qMakeJob(slug: "x"), settings: settings)
        #expect(result.status == .failed)
        // テスト中は失敗記録の置き場所が既定で無いので、フォルダは無いまま。
        #expect(result.outputDir == "")
        let summary = try #require(result.errorSummary)
        #expect(summary.contains("出力フォルダを作れませんでした: \(blocker.path)"))
        #expect(summary.contains("OS のエラー: File exists (errno 17)"))
        #expect(!result.fullPrompt.isEmpty, "再試行できるよう、組み立てたプロンプトは記録に入れる")
        #expect(runner.recordedInvocations.isEmpty)
        #expect(f.events.count == 0)
    }

    @Test func failedRecordsDirectoryIsOffByDefaultInTests() throws {
        let executor = JobExecutor(runner: QMockRunner { _, _ in ProcessOutcome(exitCode: 0) })
        #expect(executor.failedRecordsDirectory == nil, "テストでユーザーの Application Support に書かない")
        #expect(RunFolder.defaultFailedRecordsDirectory.lastPathComponent == RunFolder.failedRecordsDirectoryName)
        #expect(RunFolder.defaultFailedRecordsDirectory.deletingLastPathComponent().standardizedFileURL.path
            == HistoryStore.default.indexURL.deletingLastPathComponent().standardizedFileURL.path)
        #expect(HistoryStore.default.failedRecordsDirectory?.standardizedFileURL.path
            == RunFolder.defaultFailedRecordsDirectory.standardizedFileURL.path)
    }

    @Test func outputFolderFailureIsKeptInFailedRecordsDirectory() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        let blocker = f.tmp.url.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let support = f.tmp.sub("support")
        let failedDir = support.appendingPathComponent(RunFolder.failedRecordsDirectoryName, isDirectory: true)
        let runner = QMockRunner(QMockRunner.writingImages(["lost-01.png"]))
        var executor = f.executor(runner)
        executor.failedRecordsDirectory = failedDir
        let job = qMakeJob(slug: "lost", prompt: "迷子の猫", count: 2, referenceImages: ["/refs/a.png"])
        let result = await executor.execute(job, settings: qSettings(outputDirectory: blocker, codexPath: f.codexPath)) { _ in }

        #expect(result.status == .failed)
        #expect(result.id == job.id)
        #expect(runner.recordedInvocations.isEmpty)
        let folder = URL(fileURLWithPath: result.outputDir)
        #expect(folder.deletingLastPathComponent().standardizedFileURL.path == failedDir.standardizedFileURL.path)
        let summary = try #require(result.errorSummary)
        #expect(summary.contains("出力フォルダを作れませんでした: \(blocker.path)"))
        #expect(summary.contains("OS のエラー: File exists (errno 17)"))
        #expect(summary.contains(folder.path))
        #expect(result.fullPrompt.contains("迷子の猫"))

        // フォルダの中身は普通のジョブと同じ形（run.json と prompt.txt）。
        let saved = try RunFolder.readRecord(from: folder)
        #expect(saved.id == job.id)
        #expect(saved.status == .failed)
        #expect(saved.errorSummary == summary)
        #expect(saved.fullPrompt == result.fullPrompt)
        #expect(RunFolder.readText(folder.appendingPathComponent(RunFolder.promptFileName)) == result.fullPrompt)

        // 再起動したあと（索引なし）でも履歴に出て、同じ内容で再試行できる。
        let history = HistoryStore(indexURL: support.appendingPathComponent("history.json"))
        let loaded = try #require(history.loadAll(outputDirectory: f.out).first)
        #expect(loaded.id == job.id)
        #expect(loaded.status == .failed)
        let retry = loaded.makeRetry(now: Date())
        #expect(retry.prompt == "迷子の猫")
        #expect(retry.slug == "lost")
        #expect(retry.count == 2)
        #expect(retry.referenceImages == ["/refs/a.png"])
        #expect(retry.fullPrompt == result.fullPrompt)

        // 履歴から消すと、置き場所のフォルダも消える。
        try history.delete(loaded)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func unwritableOutputDirectoryNamesTheOSError() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        let readOnly = f.tmp.sub("read-only")
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }
        let out = readOnly.appendingPathComponent("Images", isDirectory: true)
        let runner = QMockRunner(QMockRunner.writingImages(["x-01.png"]))
        let result = await f.run(runner, job: qMakeJob(slug: "x"), settings: qSettings(outputDirectory: out, codexPath: f.codexPath))
        #expect(result.status == .failed)
        let summary = try #require(result.errorSummary)
        #expect(summary.contains("出力フォルダを作れませんでした: \(out.path)"))
        #expect(summary.contains("OS のエラー: Permission denied (errno 13)"))
        #expect(runner.recordedInvocations.isEmpty)
    }

    @Test func runningFolderIsHiddenFromHistoryAndCannotBeDeleted() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        let folders = QLog<URL>()
        let released = QLog<Bool>()
        let runner = QMockRunner { invocation, _ in
            folders.append(invocation.workingDirectory)
            while released.count == 0 {
                try? await Task.sleep(for: .milliseconds(5))
            }
            try qPNGData().write(to: invocation.workingDirectory.appendingPathComponent("live-01.png"))
            return ProcessOutcome(exitCode: 0)
        }
        let executor = f.executor(runner)
        let settings = f.settings()
        let task = Task { await executor.execute(qMakeJob(slug: "live"), settings: settings) { _ in } }
        #expect(await qWaitUntil { folders.count == 1 })
        let folder = try #require(folders.all.first)
        #expect(RunFolder.isInUse(folder))

        // 実行中に履歴を読み直しても「中止」として出さず、削除を頼まれても消さない。
        let history = HistoryStore(indexURL: f.tmp.url.appendingPathComponent("h.json"))
        #expect(history.loadAll(outputDirectory: f.out).isEmpty)
        let onDisk = try RunFolder.readRecord(from: folder)
        #expect(onDisk.status == .running)
        #expect(throws: RunFolderError.inUse(folder.path)) {
            try history.delete(onDisk, allowingInterrupted: true)
        }
        for name in [RunFolder.recordFileName, RunFolder.promptFileName, RunFolder.stdoutFileName, RunFolder.stderrFileName] {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "\(name)")
        }

        released.append(true)
        let result = await task.value
        #expect(result.status == .done)
        #expect(!RunFolder.isInUse(folder))
        let loaded = history.loadAll(outputDirectory: f.out)
        #expect(loaded.map(\.id) == [result.id])
        #expect(loaded.first?.status == .done)
    }

    @Test func clearsStaleRunFieldsFromInput() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        var job = qMakeJob(slug: "s")
        job.status = .failed
        job.errorSummary = "前回の失敗"
        job.images = ["/old.png"]
        job.exitCode = 9
        let runner = QMockRunner(QMockRunner.writingImages(["s-01.png"]))
        let result = await f.run(runner, job: job)
        #expect(result.status == .done)
        #expect(result.errorSummary == nil)
        #expect(result.exitCode == 0)
        #expect(result.images.count == 1)
    }

    @Test func concurrentExecutionsUseSeparateFolders() async throws {
        let f = try QExecutorFixture()
        defer { f.tmp.remove() }
        let runner = QMockRunner(QMockRunner.writingImages(["same-01.png"], delay: .milliseconds(20)))
        let executor = f.executor(runner)
        let settings = f.settings()
        let results = await withTaskGroup(of: JobRecord.self) { group in
            for _ in 0..<6 {
                group.addTask { await executor.execute(qMakeJob(slug: "same"), settings: settings) { _ in } }
            }
            var all: [JobRecord] = []
            for await r in group { all.append(r) }
            return all
        }
        #expect(results.allSatisfy { $0.status == .done })
        #expect(Set(results.map(\.outputDir)).count == 6)
        #expect(results.allSatisfy { $0.images.count == 1 })
    }
}
