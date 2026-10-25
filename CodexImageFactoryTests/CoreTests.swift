import Foundation
import Testing
@testable import CodexImageFactory

@Suite("ShellQuote")
struct ShellQuoteTests {
    @Test func plainArgumentsStayUnquoted() {
        #expect(ShellQuote.quote("exec") == "exec")
        #expect(ShellQuote.quote("--skip-git-repo-check") == "--skip-git-repo-check")
        #expect(ShellQuote.quote("/Users/a/Pictures/CodexImages/x-01.png") == "/Users/a/Pictures/CodexImages/x-01.png")
    }

    @Test func emptyArgumentBecomesEmptyQuotes() {
        #expect(ShellQuote.quote("") == "''")
    }

    @Test func spacesAndJapaneseAreQuoted() {
        #expect(ShellQuote.quote("a b") == "'a b'")
        #expect(ShellQuote.quote("猫の絵") == "'猫の絵'")
        #expect(ShellQuote.quote("/Users/a/My Pictures") == "'/Users/a/My Pictures'")
    }

    @Test func singleQuoteIsEscaped() {
        #expect(ShellQuote.quote("it's") == "'it'\\''s'")
    }

    @Test func shellMetacharactersAreQuoted() {
        for s in ["$HOME", "`ls`", "a;b", "a&b", "a|b", "*", "a\"b", "!x", "a\\b", "~", "(x)", "#x"] {
            let q = ShellQuote.quote(s)
            #expect(q.hasPrefix("'") && q.hasSuffix("'"), "\(s) → \(q)")
        }
    }

    @Test func leadingEqualsIsQuoted() {
        // zsh は単語の先頭の `=cmd` をコマンドのパスに展開する。
        #expect(ShellQuote.quote("=ls") == "'=ls'")
        #expect(ShellQuote.quote("a=b") == "a=b")
    }

    @Test func controlCharactersUseANSICQuotingOnOneLine() {
        let q = ShellQuote.quote("一行目\n二行目\tタブ it's \\ 100%!")
        #expect(q == "$'一行目\\n二行目\\tタブ it\\'s \\\\ 100%\\x21'")
        #expect(!q.contains("\n"))
        #expect(!q.contains("\t"))
        #expect(!q.contains("!"))
        // 改行を含むプロンプトでも、コマンド全体が 1 行になる。
        let o = CommandBuilder.Options(codexPath: "/opt/codex", workingDirectory: "/out", prompt: "猫\n\n画像生成ツールを使って…")
        #expect(!CommandBuilder.commandLine(o).contains("\n"))
    }

    @Test(arguments: ["/bin/zsh", "/bin/bash"])
    func joinRoundTripsThroughShell(shell: String) throws {
        let args = [
            "printf", "%s\\n", "a b", "it's", "$HOME", "改行\nあり", "`x`", "", "-- x",
            "タブ\tと CR\rと\u{07}ベル", "末尾のバックスラッシュ\\", "感嘆符! と '引用'\n", "=ls", "🐈‍⬛ 絵文字",
        ]
        let line = ShellQuote.join(args)
        #expect(!line.contains("\n"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = shell.hasSuffix("zsh") ? ["-f", "-c", line] : ["--norc", "--noprofile", "-c", line]
        let out = Pipe()
        p.standardOutput = out
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(p.terminationStatus == 0)
        #expect(text == args.dropFirst(2).map { $0 + "\n" }.joined())
    }
}

@Suite("Slug")
struct SlugTests {
    @Test func sanitizeReplacesUnsafeCharacters() {
        #expect(Slug.sanitize("kina mascot") == "kina-mascot")
        #expect(Slug.sanitize("a/b\\c:d") == "a-b-c-d")
        #expect(Slug.sanitize("  --hello--  ") == "hello")
        #expect(Slug.sanitize("a   b") == "a-b")
        #expect(Slug.sanitize("キナ マスコット") == "キナ-マスコット")
        #expect(Slug.sanitize("../../etc") == "etc")
        #expect(Slug.sanitize("$(rm -rf)") == "(rm-rf)")
        #expect(Slug.sanitize("") == "")
    }

    @Test func sanitizeLimitsLength() {
        let long = String(repeating: "a", count: 200)
        #expect(Slug.sanitize(long).count == Slug.maxLength)
    }

    @Test func timestampFormat() {
        // 2026-10-24 15:30:12 UTC = 2026-10-25 00:30:12 JST
        let date = Date(timeIntervalSince1970: 1_792_855_812)
        #expect(Slug.timestamp(date, timeZone: TimeZone(identifier: "UTC")!) == "20261024-153012")
        #expect(Slug.timestamp(date, timeZone: TimeZone(identifier: "Asia/Tokyo")!) == "20261025-003012")
        #expect(Slug.isTimestamp("20261024-153012"))
        #expect(!Slug.isTimestamp("kina-mascot"))
        #expect(!Slug.isTimestamp("20261024_153012"))
        #expect(!Slug.isTimestamp("20261024-15301"))
    }

    @Test func effectiveFallsBackToTimestamp() {
        let tz = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 0)
        #expect(Slug.effective("", date: date, timeZone: tz) == "19700101-000000")
        #expect(Slug.effective("   ", date: date, timeZone: tz) == "19700101-000000")
        #expect(Slug.effective("cat", date: date, timeZone: tz) == "cat")
    }

    @Test func folderName() {
        let tz = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 0)
        #expect(Slug.folderName(slug: "kina-mascot", startedAt: date, timeZone: tz) == "19700101-000000-kina-mascot")
        #expect(Slug.folderName(slug: "20261024-153012", startedAt: date, timeZone: tz) == "19700101-000000")
    }
}

@Suite("PromptBuilder")
struct PromptBuilderTests {
    @Test func expectedFileNames() {
        #expect(PromptBuilder.expectedFileNames(slug: "kina", count: 1) == ["kina-01.png"])
        #expect(PromptBuilder.expectedFileNames(slug: "kina", count: 4) == ["kina-01.png", "kina-02.png", "kina-03.png", "kina-04.png"])
    }

    @Test func instructionFillsAllPlaceholders() {
        let s = PromptBuilder.instruction(
            template: AppSettings.defaultInstructionTemplate,
            slug: "kina",
            count: 2,
            aspect: .landscape,
            background: .transparent
        )
        #expect(s.contains("2 枚生成"))
        #expect(s.contains("`kina-01.png`、`kina-02.png`"))
        #expect(s.contains("横長（3:2）"))
        #expect(s.contains("背景は透明"))
        #expect(!s.contains("{"))
    }

    @Test func unspecifiedBackgroundIsOmitted() {
        let s = PromptBuilder.instruction(
            template: AppSettings.defaultInstructionTemplate,
            slug: "x", count: 1, aspect: .square, background: .unspecified
        )
        #expect(!s.contains("背景"))
        #expect(s.contains("サイズは正方形（1:1）。ファイルを保存したら"))
    }

    @Test func buildOrderAndPresetOmission() {
        #expect(PromptBuilder.build(preset: "スタイル", prompt: "本文", instruction: "指示") == "スタイル\n\n本文\n\n指示")
        #expect(PromptBuilder.build(preset: "  ", prompt: "本文", instruction: "指示") == "本文\n\n指示")
    }

    @Test func customTemplate() {
        let s = PromptBuilder.instruction(template: "{slug}/{count}/{size}/{background}", slug: "a", count: 4, aspect: .portrait, background: .white)
        #expect(s == "a/4/縦長（2:3）/背景は白。")
    }

    @Test func splitBatchOnBlankLines() {
        let text = "猫\n二行目\n\n\n犬\n   \n鳥\n"
        #expect(PromptBuilder.splitBatch(text) == ["猫\n二行目", "犬", "鳥"])
        #expect(PromptBuilder.splitBatch("\n\n  \n").isEmpty)
    }
}

@Suite("CommandBuilder")
struct CommandBuilderTests {
    @Test func basicCommandMatchesSpec() {
        let o = CommandBuilder.Options(codexPath: "/opt/codex", workingDirectory: "/out/dir", prompt: "猫")
        #expect(CommandBuilder.command(o) == [
            "/opt/codex", "exec",
            "-C", "/out/dir",
            "-s", "workspace-write",
            "--skip-git-repo-check",
            "--json",
            "-o", "/out/dir/last-message.md",
            "--", "猫",
        ])
    }

    @Test func optionalFlags() {
        let o = CommandBuilder.Options(
            codexPath: "/opt/codex",
            workingDirectory: "/out",
            prompt: "p",
            referenceImages: ["/a.png", "/b c.png"],
            model: "gpt-x",
            reasoningEffort: .low,
            ephemeral: true
        )
        let args = CommandBuilder.arguments(o)
        #expect(args.suffix(2) == ["--", "p"])
        #expect(args.contains("--ephemeral"))
        let m = args.firstIndex(of: "-m")!
        #expect(args[m + 1] == "gpt-x")
        let c = args.firstIndex(of: "-c")!
        #expect(args[c + 1] == "model_reasoning_effort=\"low\"")
        let images = args.indices.filter { args[$0] == "-i" }.map { args[$0 + 1] }
        #expect(images == ["/a.png", "/b c.png"])
    }

    @Test func commandLineIsShellQuoted() {
        let o = CommandBuilder.Options(codexPath: "/opt/codex", workingDirectory: "/My Out", prompt: "it's a cat")
        let line = CommandBuilder.commandLine(o)
        #expect(line.hasPrefix("/opt/codex exec -C '/My Out' "))
        #expect(line.hasSuffix(" -- 'it'\\''s a cat'"))
    }
}

@Suite("ImageDetector")
struct ImageDetectorTests {
    static let pngBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]

    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cif-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func detectsOnlyNewImageFiles() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(Self.pngBytes).write(to: dir.appendingPathComponent("old.png"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("run.json"))
        let before = ImageDetector.snapshot(directory: dir)
        #expect(before == ["old.png"])

        try Data(Self.pngBytes).write(to: dir.appendingPathComponent("b-02.png"))
        try Data(Self.pngBytes).write(to: dir.appendingPathComponent("b-01.PNG"))
        try Data(Self.pngBytes).write(to: dir.appendingPathComponent("c.webp"))
        try Data(Self.pngBytes).write(to: dir.appendingPathComponent("d.jpg"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data(Self.pngBytes).write(to: dir.appendingPathComponent(".hidden.png"))
        let sub = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(Self.pngBytes).write(to: sub.appendingPathComponent("e.jpeg"))

        let new = ImageDetector.newImages(before: before, directory: dir)
        #expect(new == ["b-01.PNG", "b-02.png", "c.webp", "d.jpg", "out/e.jpeg"])
    }

    @Test func orderedPrefersExpectedNames() {
        let r = ImageDetector.ordered(["z.png", "a-02.png", "a-01.png", "b.png"], expected: ["a-01.png", "a-02.png"])
        #expect(r == ["a-01.png", "a-02.png", "b.png", "z.png"])
    }

    @Test func parsesFileNamesFromLastMessage() {
        let msg = """
        保存しました:
        - `kina-01.png`
        2. kina-02.png
        ./kina-03.png
        **kina-04.png**
        これは説明文です.png じゃない行
        notes.txt
        """
        #expect(ImageDetector.fileNamesListed(in: msg) == ["kina-01.png", "kina-02.png", "kina-03.png", "kina-04.png"])
    }

    @Test func extractsBase64ImageFromJSONL() throws {
        let png = Data(Self.pngBytes + [UInt8](repeating: 7, count: 300))
        let b64 = png.base64EncodedString()
        let line1 = #"{"type":"item.completed","item":{"type":"image_generation","result":"\#(b64)"}}"#
        let found1 = ImageDetector.extractBase64Images(fromJSONLLine: line1)
        #expect(found1.count == 1)
        #expect(found1.first?.data == png)
        #expect(found1.first?.fileExtension == "png")

        let line2 = #"{"type":"x","url":"data:image/png;base64,\#(b64)"}"#
        #expect(ImageDetector.extractBase64Images(fromJSONLLine: line2).count == 1)

        let text = String(repeating: "abc ", count: 100)
        let line3 = #"{"type":"item.completed","item":{"type":"agent_message","text":"\#(text)"}}"#
        #expect(ImageDetector.extractBase64Images(fromJSONLLine: line3).isEmpty)
        #expect(ImageDetector.extractBase64Images(fromJSONLLine: "not json").isEmpty)
    }

    @Test func threadIdFromThreadStarted() {
        #expect(ImageDetector.threadId(fromJSONLLine: #"{"type":"thread.started","thread_id":"01a16e60-88f0"}"#) == "01a16e60-88f0")
        #expect(ImageDetector.threadId(fromJSONLLine: #"{"type":"turn.started"}"#) == nil)
        #expect(ImageDetector.threadId(fromJSONLLine: "garbage thread") == nil)
    }

    @Test func generatedImagesFallback() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent("generated_images/thread-1", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(Self.pngBytes).write(to: dir.appendingPathComponent("exec-a.png"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("log.txt"))
        let found = ImageDetector.generatedImages(codexHome: home, threadId: "thread-1")
        #expect(found.map(\.lastPathComponent) == ["exec-a.png"])
        #expect(ImageDetector.generatedImages(codexHome: home, threadId: "../x").isEmpty)
        #expect(ImageDetector.generatedImages(codexHome: home, threadId: "missing").isEmpty)
    }
}

@Suite("RateLimitDetector")
struct RateLimitDetectorTests {
    @Test func stderrPatterns() {
        #expect(RateLimitDetector.isRateLimited(stream: .stderr, line: "ERROR: unexpected status 429 Too Many Requests"))
        #expect(RateLimitDetector.isRateLimited(stream: .stderr, line: "You've hit your usage limit. Try again later."))
        #expect(RateLimitDetector.isRateLimited(stream: .stderr, line: "rate limit exceeded"))
        #expect(!RateLimitDetector.isRateLimited(stream: .stderr, line: "Reading additional input from stdin..."))
        #expect(!RateLimitDetector.isRateLimited(stream: .stderr, line: "ERROR codex_core::tools::router: error=collab spawn failed: no thread with id: 01a16e60-9055-7233-a429e-880d6d0d1bfe"))
        #expect(!RateLimitDetector.isRateLimited(stream: .stderr, line: "wrote 14290 bytes"))
    }

    @Test func stdoutOnlyErrorEvents() {
        let err = #"{"type":"error","message":"{\"type\":\"error\",\"status\":429,\"error\":{\"message\":\"Rate limit reached\"}}"}"#
        #expect(RateLimitDetector.isRateLimited(stream: .stdout, line: err))
        let failed = #"{"type":"turn.failed","error":{"message":"You've hit your usage limit"}}"#
        #expect(RateLimitDetector.isRateLimited(stream: .stdout, line: failed))
        // コマンド出力や返答本文に含まれていても反応しない
        let cmd = #"{"type":"item.completed","item":{"type":"command_execution","aggregated_output":"handle rate limit and 429 errors"}}"#
        #expect(!RateLimitDetector.isRateLimited(stream: .stdout, line: cmd))
        let msg = #"{"type":"item.completed","item":{"type":"agent_message","text":"rate limit"}}"#
        #expect(!RateLimitDetector.isRateLimited(stream: .stdout, line: msg))
        // 無害な警告（item.type == error）にも反応しない
        let warn = #"{"type":"item.completed","item":{"type":"error","message":"Under-development features enabled: chronicle."}}"#
        #expect(!RateLimitDetector.isRateLimited(stream: .stdout, line: warn))
        let model = #"{"type":"error","message":"{\"status\":400,\"error\":{\"message\":\"model not supported\"}}"}"#
        #expect(!RateLimitDetector.isRateLimited(stream: .stdout, line: model))
    }
}

@Suite("JSONLLog")
struct JSONLLogTests {
    @Test func formatsKnownEvents() {
        #expect(JSONLLog.format(line: #"{"type":"thread.started","thread_id":"abc"}"#) == "[thread.started] thread_id=abc")
        #expect(JSONLLog.format(line: #"{"type":"item.completed","item":{"id":"i","type":"agent_message","text":"done"}}"#) == "[item.completed · agent_message] done")
        let cmd = JSONLLog.format(line: #"{"type":"item.completed","item":{"type":"command_execution","command":"ls","aggregated_output":"a\nb","exit_code":0}}"#)
        #expect(cmd.hasPrefix("[item.completed · command_execution] $ ls（終了コード 0）"))
        #expect(cmd.contains("a\n    b"))
        #expect(JSONLLog.format(line: #"{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}"#) == "[turn.completed] 入力トークン 10 / 出力トークン 2")
        #expect(JSONLLog.format(line: #"{"type":"turn.failed","error":{"message":"boom"}}"#) == "[turn.failed] boom")
    }

    @Test func unknownAndInvalidLines() {
        #expect(JSONLLog.format(line: "plain text") == "plain text")
        #expect(JSONLLog.format(line: #"{"type":"turn.started"}"#) == "[turn.started]")
        #expect(JSONLLog.format(line: #"{"type":"new.kind","foo":1}"#) == #"[new.kind] {"foo":1}"#)
        #expect(JSONLLog.format(line: "{broken") == "{broken")
    }

    @Test func longOutputIsTruncated() {
        let long = String(repeating: "x", count: 5000)
        let line = #"{"type":"item.completed","item":{"type":"command_execution","command":"cat a","aggregated_output":"\#(long)","exit_code":0}}"#
        #expect(JSONLLog.format(line: line).count < 1000)
    }
}

@Suite("JobFactory")
struct JobFactoryTests {
    let template = AppSettings.defaultInstructionTemplate
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func singleRequiresPrompt() {
        #expect(JobFactory.single(from: JobDraft(prompt: "  \n "), preset: "", template: template, now: now) == nil)
        let job = JobFactory.single(from: JobDraft(prompt: " 猫 ", slug: "my cat", count: 2), preset: "水彩", template: template, now: now)!
        #expect(job.prompt == "猫")
        #expect(job.slug == "my-cat")
        #expect(job.count == 2)
        #expect(job.preset == "水彩")
        #expect(job.status == .queued)
        #expect(job.fullPrompt.hasPrefix("水彩\n\n猫\n\n画像生成ツールを使って 2 枚"))
    }

    @Test func emptySlugUsesTimestamp() {
        let job = JobFactory.single(from: JobDraft(prompt: "猫"), preset: "", template: template, now: now)!
        #expect(Slug.isTimestamp(job.slug))
    }

    @Test func batchSplitsAndNumbersSlugs() {
        let draft = JobDraft(prompt: "猫\n\n犬\n\n鳥", slug: "pet", count: 4, aspect: .portrait, background: .white, referenceImages: ["/r.png"])
        let jobs = JobFactory.batch(from: draft, preset: "p", template: template, now: now)
        #expect(jobs.map(\.prompt) == ["猫", "犬", "鳥"])
        #expect(jobs.map(\.slug) == ["pet-1", "pet-2", "pet-3"])
        #expect(jobs.allSatisfy { $0.count == 4 && $0.aspect == .portrait && $0.background == .white && $0.preset == "p" && $0.referenceImages == ["/r.png"] })
        #expect(Set(jobs.map(\.id)).count == 3)
        #expect(jobs[0].createdAt < jobs[1].createdAt)
    }

    @Test func batchWithoutSlugGivesDistinctTimestamps() {
        let jobs = JobFactory.batch(from: JobDraft(prompt: "猫\n\n犬\n\n鳥"), preset: "", template: template, now: now)
        #expect(jobs.count == 3)
        #expect(jobs.allSatisfy { Slug.isTimestamp($0.slug) })
        #expect(Set(jobs.map(\.slug)).count == 3, "行とボタンのラベルを見分けられる")
    }

    @Test func batchWithSinglePromptKeepsSlug() {
        let jobs = JobFactory.batch(from: JobDraft(prompt: "猫", slug: "pet"), preset: "", template: template, now: now)
        #expect(jobs.map(\.slug) == ["pet"])
    }

    @Test func invalidCountFallsBackAndReferencesAreCapped() {
        let draft = JobDraft(prompt: "x", count: 3, referenceImages: ["/1", "/2", "/3", "/4", "/5"])
        let job = JobFactory.single(from: draft, preset: "", template: template, now: now)!
        #expect(job.count == 1)
        #expect(job.referenceImages.count == ReferenceImageLimit.max)
    }

    @Test func editKeepsPresetAndIdentity() {
        let job = JobFactory.single(from: JobDraft(prompt: "猫", slug: "a"), preset: "古いプリセット", template: template, now: now)!
        let edited = JobFactory.apply(JobDraft(prompt: "犬", slug: "b", count: 2), to: job, template: template)!
        #expect(edited.id == job.id)
        #expect(edited.preset == "古いプリセット")
        #expect(edited.prompt == "犬")
        #expect(edited.slug == "b")
        #expect(edited.count == 2)
        #expect(JobFactory.apply(JobDraft(prompt: ""), to: job, template: template) == nil)
    }

    @Test func draftFromJobHidesTimestampSlug() {
        let job = JobFactory.single(from: JobDraft(prompt: "猫"), preset: "", template: template, now: now)!
        #expect(JobFactory.draft(from: job).slug == "")
        let named = JobFactory.single(from: JobDraft(prompt: "猫", slug: "neko"), preset: "", template: template, now: now)!
        #expect(JobFactory.draft(from: named).slug == "neko")
    }
}

@Suite("JobRecord")
struct JobRecordTests {
    @Test func queueLineFormat() {
        let created = Date(timeIntervalSince1970: 0)
        var job = JobRecord(createdAt: created, slug: "kina-mascot", prompt: "p", preset: "", count: 1, aspect: .square, background: .transparent)
        #expect(job.queueLine(now: created.addingTimeInterval(42)) == "待機中 · kina-mascot · 0:42")
        job.status = .running
        job.startedAt = created.addingTimeInterval(10)
        #expect(job.queueLine(now: created.addingTimeInterval(10 + 125)) == "実行中 · kina-mascot · 2:05")
        job.status = .done
        job.finishedAt = created.addingTimeInterval(10 + 3725)
        #expect(job.queueLine(now: .distantFuture) == "完了 · kina-mascot · 1:02:05")
    }

    @Test func lenientDecoding() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","prompt":"猫","futureField":true}"#
        let job = try JSONDecoder().decode(JobRecord.self, from: Data(json.utf8))
        #expect(job.id == id)
        #expect(job.prompt == "猫")
        #expect(job.images.isEmpty)
    }

    @Test func retryCopiesInputsOnly() {
        var job = JobRecord(createdAt: .distantPast, slug: "s", prompt: "p", preset: "pr", count: 2, aspect: .portrait, background: .white, referenceImages: ["/r"])
        job.status = .failed
        job.outputDir = "/x"
        job.images = ["/x/a.png"]
        let retry = job.makeRetry(now: Date(timeIntervalSince1970: 5))
        #expect(retry.id != job.id)
        #expect(retry.status == .queued)
        #expect(retry.outputDir.isEmpty && retry.images.isEmpty)
        #expect(retry.prompt == "p" && retry.preset == "pr" && retry.count == 2 && retry.aspect == .portrait && retry.referenceImages == ["/r"])
    }
}
