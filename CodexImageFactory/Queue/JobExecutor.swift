import Foundation
import Synchronization

/// ジョブ実行中に届く出来事。
enum JobEvent: Sendable {
    /// フォルダを作り、コマンドを組み立てて起動する直前。outputDir / command / commandLine / fullPrompt / startedAt が入っている。
    case started(JobRecord)
    /// stdout / stderr の 1 行（生のまま）。
    case line(CodexStream, String)
    /// レート制限らしきエラーを検出した（1 ジョブにつき最初の 1 回だけ）。
    case rateLimited(String)
}

/// ジョブ 1 件を実行する部品。キューのテストではダミーに差し替える。
protocol JobExecuting: Sendable {
    /// ジョブを実行し、終わった状態（done / failed / cancelled）のレコードを返す。throw しない。
    /// 呼び出し側の Task がキャンセルされたら codex を止めて cancelled を返す。
    func execute(
        _ job: JobRecord,
        settings: AppSettings,
        onEvent: @escaping @Sendable (JobEvent) -> Void
    ) async -> JobRecord
}

/// 本番用の実行部品。フォルダ作成 → prompt.txt / run.json → codex exec → 画像検出 → run.json 更新。
struct JobExecutor: JobExecuting {
    var runner: any CodexRunning
    /// Codex のホーム（`~/.codex`）。画像の予備の取り出しに使う。
    var codexHome: URL
    /// 子プロセスに渡す環境変数を返す。
    var environment: @Sendable () async -> [String: String]
    var now: @Sendable () -> Date
    /// 出力フォルダを作れなかったジョブの記録（run.json と prompt.txt）を置く場所。nil なら残さない。
    /// 既定は `RunFolder.defaultFailedRecordsDirectory`（`HistoryStore.default` が走査する場所）。
    /// テスト中はユーザーの Application Support に書かないよう、既定で nil にする。
    var failedRecordsDirectory: URL?

    /// 失敗の要約の上限文字数。
    static let maxErrorSummaryLength = 2000
    /// 失敗の要約に入れる stderr の末尾の行数。
    static let errorSummaryStderrLines = 10
    /// 実行中に覚えておく stderr の末尾の行数。
    static let stderrTailCapacity = 40
    /// codex が stdin を読みに行くときに出す行。stdin は /dev/null なので無害。要約には入れない。
    static let stdinNoticePrefix = "Reading additional input from stdin"

    static let cancelledSummary = String(localized: "中止しました")
    static let missingCodexPathSummary = String(localized: "codex のパスが設定されていません。設定の「codex のパス」を確認してください。")
    static let noImagesSummary = String(localized: "画像ファイルが見つかりませんでした")

    init(
        runner: any CodexRunning,
        codexHome: URL = PathUtil.codexHome(),
        environment: @escaping @Sendable () async -> [String: String] = { await CodexEnvironmentCache.shared.environment() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.codexHome = codexHome
        self.environment = environment
        self.now = now
        failedRecordsDirectory = RuntimeEnvironment.isRunningTests ? nil : RunFolder.defaultFailedRecordsDirectory
    }

    func execute(
        _ job: JobRecord,
        settings: AppSettings,
        onEvent: @escaping @Sendable (JobEvent) -> Void
    ) async -> JobRecord {
        let start = now()
        let settings = settings.normalized()
        var record = job
        record.status = .running
        record.startedAt = start
        record.finishedAt = nil
        record.exitCode = nil
        record.outputDir = ""
        record.command = []
        record.commandLine = ""
        record.images = []
        record.lastMessage = ""
        record.errorSummary = nil
        record.codexThreadId = nil

        if Task.isCancelled {
            return finish(record, status: .cancelled, summary: Self.cancelledSummary, folder: nil)
        }

        // 1. プロンプトを組み立てる（フォルダを作れなくても、再試行できるように記録へ入れる）。
        let codexPath = PathUtil.expandTilde(settings.codexPath.trimmingCharacters(in: .whitespacesAndNewlines))
        let references = job.referenceImages
            .map { PathUtil.expandTilde($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
        let fullPrompt = PromptBuilder.fullPrompt(for: job, template: settings.instructionTemplate)
        record.fullPrompt = fullPrompt
        record.referenceImages = references

        // 2. フォルダを作る。作れなければ、失敗の記録を予備の置き場所に残して返す。
        let folder: URL
        do {
            folder = try RunFolder.create(in: settings.outputDirectoryURL, slug: job.slug, startedAt: start)
        } catch {
            let summary = Self.folderFailureSummary(outputDirectory: settings.outputDirectoryURL, error: error)
            return finishWithoutFolder(record, summary: summary)
        }
        // 実行中の印。履歴の読み込み・削除はこのフォルダを避ける（終わって run.json を書いたあとに外す）。
        RunFolder.beginUse(folder)
        defer { RunFolder.endUse(folder) }

        // 3. コマンドを組み立てる。
        let options = CommandBuilder.Options(
            codexPath: codexPath,
            workingDirectory: folder.path,
            prompt: fullPrompt,
            referenceImages: references,
            model: settings.model,
            reasoningEffort: settings.reasoningEffort,
            ephemeral: settings.useEphemeral
        )
        record.outputDir = folder.path
        record.command = CommandBuilder.command(options)
        record.commandLine = CommandBuilder.commandLine(options)

        // 4. 起動前に記録ファイルを置く（途中で落ちても履歴に残るように）。
        let stdoutURL = folder.appendingPathComponent(RunFolder.stdoutFileName)
        let stderrURL = folder.appendingPathComponent(RunFolder.stderrFileName)
        try? Data(fullPrompt.utf8).write(to: folder.appendingPathComponent(RunFolder.promptFileName), options: .atomic)
        FileManager.default.createFile(atPath: stdoutURL.path, contents: Data())
        FileManager.default.createFile(atPath: stderrURL.path, contents: Data())
        try? RunFolder.writeRecord(record, to: folder)
        onEvent(.started(record))

        // 5. 起動前の確認。失敗もフォルダに記録する。
        if let problem = Self.preflightProblem(codexPath: codexPath, references: references) {
            return finish(record, status: .failed, summary: problem, folder: folder)
        }

        let before = ImageDetector.snapshot(directory: folder)
        let env = await environment()
        if Task.isCancelled {
            return finish(record, status: .cancelled, summary: Self.cancelledSummary, folder: folder)
        }
        let invocation = CodexInvocation(
            executableURL: URL(fileURLWithPath: codexPath),
            arguments: Array(record.command.dropFirst()),
            workingDirectory: folder,
            environment: env,
            timeout: TimeInterval(settings.timeoutSeconds)
        )

        // 6. 実行。届いた行はファイルに追記し、そのまま呼び出し側へ流す。
        let collector = JobExecutorLineCollector(
            stdout: try? FileHandle(forWritingTo: stdoutURL),
            stderr: try? FileHandle(forWritingTo: stderrURL)
        )
        let onLine: @Sendable (CodexStream, String) -> Void = { stream, line in
            let parsed = JobExecutorParsedLine(stream: stream, line: line)
            let reportRateLimit = collector.absorb(stream: stream, line: line, parsed: parsed)
            onEvent(.line(stream, line))
            if reportRateLimit {
                onEvent(.rateLimited(line))
            }
        }

        let outcome: ProcessOutcome
        do {
            outcome = try await runner.run(invocation, onLine: onLine)
        } catch {
            collector.closeFiles()
            let captured = collector.result()
            record.lastMessage = Self.readLastMessage(folder: folder)
            record.codexThreadId = captured.threadId
            if error is CancellationError {
                return finish(record, status: .cancelled, summary: Self.cancelledSummary, folder: folder)
            }
            let summary = Self.failureSummary(reason: error.localizedDescription, captured: captured)
            return finish(record, status: .failed, summary: summary, folder: folder)
        }
        collector.closeFiles()
        let captured = collector.result()

        // 7. 結果を集める。
        let lastMessage = Self.readLastMessage(folder: folder)
        record.lastMessage = lastMessage
        record.exitCode = Int(outcome.exitCode)
        record.codexThreadId = captured.threadId

        let fileSlug = Self.fileSlug(job.slug)
        var found = ImageDetector.newImages(before: before, directory: folder)
        if found.isEmpty, !captured.base64Images.isEmpty {
            Self.saveDecodedImages(captured.base64Images, slug: fileSlug, folder: folder)
            found = ImageDetector.newImages(before: before, directory: folder)
        }
        if found.isEmpty, let threadId = captured.threadId, !outcome.cancelled {
            let generated = ImageDetector.generatedImages(codexHome: codexHome, threadId: threadId, since: start)
            Self.copyGeneratedImages(generated, slug: fileSlug, folder: folder)
            found = ImageDetector.newImages(before: before, directory: folder)
        }
        var expected: [String] = []
        for name in PromptBuilder.expectedFileNames(slug: job.slug, count: job.count)
            + ImageDetector.fileNamesListed(in: lastMessage) where !expected.contains(name) {
            expected.append(name)
        }
        record.images = ImageDetector.ordered(found, expected: expected)
            .map { folder.appendingPathComponent($0).path }

        // 8. 成否を決める。
        if outcome.cancelled {
            return finish(record, status: .cancelled, summary: Self.cancelledSummary, folder: folder)
        }
        if outcome.timedOut {
            let reason = String(localized: "タイムアウト（\(settings.timeoutSeconds) 秒）のため中止しました")
            return finish(record, status: .failed, summary: Self.failureSummary(reason: reason, captured: captured), folder: folder)
        }
        if outcome.exitCode != 0 {
            let reason = outcome.terminatedBySignal
                ? String(localized: "codex がシグナル \(outcome.exitCode) で終了しました")
                : String(localized: "codex が終了コード \(outcome.exitCode) で終了しました")
            return finish(record, status: .failed, summary: Self.failureSummary(reason: reason, captured: captured), folder: folder)
        }
        if record.images.isEmpty {
            let summary = Self.failureSummary(reason: Self.noImagesSummary, captured: captured)
            return finish(record, status: .failed, summary: summary, folder: folder)
        }
        return finish(record, status: .done, summary: nil, folder: folder)
    }

    // MARK: - 内部

    /// 状態と終了時刻を入れ、フォルダがあれば run.json を書いて返す。
    private func finish(_ record: JobRecord, status: JobStatus, summary: String?, folder: URL?) -> JobRecord {
        var r = record
        r.status = status
        r.errorSummary = summary
        r.finishedAt = now()
        if let folder {
            try? RunFolder.writeRecord(r, to: folder)
        }
        return r
    }

    /// 出力フォルダを作れなかったとき。失敗の記録を `failedRecordsDirectory` に残せたら、そのフォルダを outputDir にする
    /// （履歴の索引に載り、アプリを再起動しても履歴から「再試行」できる）。残せなければ outputDir は空のまま。
    private func finishWithoutFolder(_ record: JobRecord, summary: String) -> JobRecord {
        var r = finish(record, status: .failed, summary: summary, folder: nil)
        guard let failedRecordsDirectory,
              let fallback = try? RunFolder.create(in: failedRecordsDirectory, slug: record.slug, startedAt: record.startedAt ?? now()) else {
            return r
        }
        var saved = r
        saved.outputDir = fallback.path
        saved.errorSummary = summary + "\n\n" + String(localized: "この記録は次の場所に残しました: \(fallback.path)")
        try? Data(saved.fullPrompt.utf8).write(to: fallback.appendingPathComponent(RunFolder.promptFileName), options: .atomic)
        do {
            try RunFolder.writeRecord(saved, to: fallback)
            r = saved
        } catch {
            try? FileManager.default.removeItem(at: fallback)
        }
        return r
    }

    /// 出力フォルダを作れなかったときの要約。出力ディレクトリと OS のエラーを入れる。
    static func folderFailureSummary(outputDirectory: URL, error: any Error) -> String {
        var lines = [String(localized: "出力フォルダを作れませんでした: \(outputDirectory.path)"), error.localizedDescription]
        if let posix = posixError(in: error) {
            lines.append(String(localized: "OS のエラー: \(String(cString: strerror(posix))) (errno \(posix))"))
        }
        let ns = error as NSError
        if let path = ns.userInfo[NSFilePathErrorKey] as? String, path != outputDirectory.path {
            lines.append(String(localized: "作れなかった場所: \(path)"))
        }
        lines.append(String(localized: "出力ディレクトリの設定と、ドライブがつながっているか・書き込めるかを確認してから「再試行」してください。"))
        return lines.joined(separator: "\n")
    }

    /// エラー（とその元のエラー）に入っている POSIX のエラー番号。
    private static func posixError(in error: any Error) -> Int32? {
        var current: NSError? = error as NSError
        while let ns = current {
            if ns.domain == NSPOSIXErrorDomain {
                return Int32(ns.code)
            }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    /// 起動前に分かる問題。無ければ nil。
    static func preflightProblem(codexPath: String, references: [String]) -> String? {
        let fm = FileManager.default
        if codexPath.isEmpty {
            return missingCodexPathSummary
        }
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: codexPath, isDirectory: &isDir) || isDir.boolValue || !fm.isExecutableFile(atPath: codexPath) {
            return String(localized: "codex が見つかりません: \(codexPath)")
        }
        let missing = references.filter { !fm.fileExists(atPath: $0) }
        if !missing.isEmpty {
            return String(localized: "参照画像が見つかりません:\n\(missing.joined(separator: "\n"))")
        }
        return nil
    }

    /// 失敗の要約。理由 + JSONL のエラー + stderr の末尾。長すぎれば切る。
    static func failureSummary(reason: String, captured: JobExecutorCaptured) -> String {
        var parts = [reason]
        if let message = captured.lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            parts.append(String(localized: "Codex のエラー: \(JSONLLog.truncate(message, 600))"))
        }
        let tail = captured.stderrTail.suffix(errorSummaryStderrLines)
        if !tail.isEmpty {
            parts.append(String(localized: "stderr（末尾）:\n\(tail.map { JSONLLog.truncate($0, 300) }.joined(separator: "\n"))"))
        }
        let summary = parts.joined(separator: "\n\n")
        guard summary.count > maxErrorSummaryLength else { return summary }
        return String(summary.prefix(maxErrorSummaryLength - 1)) + "…"
    }

    /// last-message.md の中身（前後の空白を除く。無ければ空文字）。
    static func readLastMessage(folder: URL) -> String {
        RunFolder.readText(folder.appendingPathComponent(RunFolder.lastMessageFileName))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 予備の取り出しで付けるファイル名のスラッグ。
    private static func fileSlug(_ slug: String) -> String {
        let s = Slug.sanitize(slug)
        return s.isEmpty ? "image" : s
    }

    /// `<slug>-NN.<ext>` のうち、まだ無い名前を返す（NN は 01 から）。
    private static func nextFreeURL(slug: String, fileExtension: String, folder: URL, counter: inout Int) -> URL {
        while true {
            let name = String(format: "%@-%02d.%@", slug, counter, fileExtension)
            counter += 1
            let url = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
    }

    /// JSONL から取り出した画像データを保存する（同じデータは 1 回だけ）。
    private static func saveDecodedImages(_ images: [(data: Data, fileExtension: String)], slug: String, folder: URL) {
        var counter = 1
        var saved: [Data] = []
        for image in images where !saved.contains(image.data) {
            saved.append(image.data)
            let url = nextFreeURL(slug: slug, fileExtension: image.fileExtension, folder: folder, counter: &counter)
            try? image.data.write(to: url)
        }
    }

    /// `~/.codex/generated_images/<thread_id>/` の画像をフォルダにコピーする（拡張子はそのまま）。
    private static func copyGeneratedImages(_ urls: [URL], slug: String, folder: URL) {
        var counter = 1
        for source in urls {
            let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
            let url = nextFreeURL(slug: slug, fileExtension: ext, folder: folder, counter: &counter)
            try? FileManager.default.copyItem(at: source, to: url)
        }
    }
}

// MARK: - 実行中の行の取り込み

/// 1 行から取り出した情報。ロックの外で解析してから渡す。
struct JobExecutorParsedLine: Sendable {
    var rateLimited: Bool
    var threadId: String?
    var images: [(data: Data, fileExtension: String)]
    var errorMessage: String?

    init(stream: CodexStream, line: String) {
        rateLimited = RateLimitDetector.isRateLimited(stream: stream, line: line)
        switch stream {
        case .stdout:
            threadId = ImageDetector.threadId(fromJSONLLine: line)
            images = ImageDetector.extractBase64Images(fromJSONLLine: line)
            errorMessage = JSONLLog.errorMessage(line: line)
        case .stderr:
            threadId = nil
            images = []
            errorMessage = nil
        }
    }
}

/// 実行が終わったあとに使う、取り込んだ情報の写し。
struct JobExecutorCaptured: Sendable {
    var threadId: String?
    var base64Images: [(data: Data, fileExtension: String)] = []
    /// stdout の JSONL の最後のエラーメッセージ。
    var lastErrorMessage: String?
    /// stderr の末尾（stdin の案内行と空行は除く）。
    var stderrTail: [String] = []
}

/// runner のコールバック（任意のスレッドから呼ばれる）で触る状態。すべて Mutex の中に置く。
private final class JobExecutorLineCollector: Sendable {
    private struct State {
        var stdoutHandle: FileHandle?
        var stderrHandle: FileHandle?
        var captured = JobExecutorCaptured()
        var rateLimitReported = false
    }

    private let state: Mutex<State>

    init(stdout: FileHandle?, stderr: FileHandle?) {
        state = Mutex(State(stdoutHandle: stdout, stderrHandle: stderr))
    }

    /// 1 行を取り込む。レート制限をこのジョブで初めて見つけたら true。
    func absorb(stream: CodexStream, line: String, parsed: JobExecutorParsedLine) -> Bool {
        let data = Data((line + "\n").utf8)
        return state.withLock { s in
            switch stream {
            case .stdout:
                // 書き込みに失敗しても（ディスクがいっぱい等）実行は続ける。
                try? s.stdoutHandle?.write(contentsOf: data)
                if s.captured.threadId == nil, let threadId = parsed.threadId {
                    s.captured.threadId = threadId
                }
                s.captured.base64Images += parsed.images
                if let message = parsed.errorMessage {
                    s.captured.lastErrorMessage = message
                }
            case .stderr:
                try? s.stderrHandle?.write(contentsOf: data)
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !trimmed.hasPrefix(JobExecutor.stdinNoticePrefix) {
                    s.captured.stderrTail.append(line)
                    let overflow = s.captured.stderrTail.count - JobExecutor.stderrTailCapacity
                    if overflow > 0 {
                        s.captured.stderrTail.removeFirst(overflow)
                    }
                }
            }
            if parsed.rateLimited, !s.rateLimitReported {
                s.rateLimitReported = true
                return true
            }
            return false
        }
    }

    /// ログファイルを閉じる。あとから行が届いてもファイルには書かない。
    func closeFiles() {
        state.withLock { s in
            try? s.stdoutHandle?.close()
            try? s.stderrHandle?.close()
            s.stdoutHandle = nil
            s.stderrHandle = nil
        }
    }

    func result() -> JobExecutorCaptured {
        state.withLock { $0.captured }
    }
}
