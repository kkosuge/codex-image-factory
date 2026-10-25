import Darwin
import Foundation
import Synchronization
import Testing
@testable import CodexImageFactory

// MARK: - テスト用の部品（他のテストからも使ってよい）

/// テスト用の一時フォルダ。使い終わったら `remove()`。
struct ProcTempDir: Sendable {
    let url: URL

    init(_ label: String = "ProcTests") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func subdirectory(_ name: String) throws -> URL {
        let dir = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// シェルスクリプトを書いて 755 にする。
enum ProcScript {
    static func write(_ body: String, name: String = "script.sh", in directory: URL, shell: String = "/bin/sh") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try ("#!\(shell)\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

/// onLine で届いた行を集める。
final class ProcLineCollector: Sendable {
    private let storage = Mutex<[(CodexStream, String)]>([])

    var onLine: @Sendable (CodexStream, String) -> Void {
        { [self] stream, line in storage.withLock { $0.append((stream, line)) } }
    }

    var all: [(CodexStream, String)] {
        storage.withLock { $0 }
    }

    func lines(_ stream: CodexStream) -> [String] {
        all.filter { $0.0 == stream }.map(\.1)
    }

    func contains(_ stream: CodexStream, _ line: String) -> Bool {
        lines(stream).contains(line)
    }

    /// `prefix` で始まる行の残りを数として読む（`child=123` → 123）。
    func pid(after prefix: String) -> pid_t? {
        for line in lines(.stdout) where line.hasPrefix(prefix) {
            return pid_t(line.dropFirst(prefix.count))
        }
        return nil
    }

    /// 条件を満たすまで待つ（最大 `timeout` 秒）。
    func waitUntil(timeout: TimeInterval = 5, _ condition: @Sendable (ProcLineCollector) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(self) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition(self)
    }
}

enum ProcWait {
    /// プロセスがいなくなるまで待つ（ゾンビは止まったものとみなす）。
    static func untilGone(_ pid: pid_t, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !ProcessSupportProcessTree.isRunning(pid) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return !ProcessSupportProcessTree.isRunning(pid)
    }
}

enum ProcPath {
    /// シンボリックリンクを解決した実パス（/var → /private/var も含む）。
    static func real(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// テスト用の最小限の環境変数。
enum ProcEnv {
    static var minimal: [String: String] {
        ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
    }
}

func procInvocation(
    _ executable: URL,
    arguments: [String] = [],
    workingDirectory: URL,
    environment: [String: String] = ProcEnv.minimal,
    timeout: TimeInterval = 20
) -> CodexInvocation {
    CodexInvocation(
        executableURL: executable,
        arguments: arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        timeout: timeout
    )
}

/// codex exec の代わりに動くダミー（シェルスクリプト）。
///
/// `-C <dir>` `-o <file>` `-- <prompt>` を引数から拾い、`<dir>` に小さな PNG を書き、JSONL を stdout に出し、
/// 保存したファイル名を `-o` のファイルに 1 行ずつ書く。`exec` `-s` `-m` `-c` `-i` などの他の引数は読み飛ばす。
///
/// - 画像の名前は `Behavior.imageNames`。nil ならプロンプト中の `` `xxx.png` `` を拾い、なければ `test-01.png`。
/// - 環境変数 `PROC_DUMMY_ARGS_FILE` があれば、受け取った引数を 1 行ずつそこに書く。
/// - SIGINT / SIGTERM を受けたら終了コード 130 で終わる（待機中でもすぐ）。
enum ProcDummyCodex {
    /// 1x1 の透明 PNG。
    static let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    static var pngData: Data { Data(base64Encoded: pngBase64)! }

    struct Behavior: Sendable {
        /// 書く画像の名前。nil ならプロンプトから拾う。
        var imageNames: [String]?
        /// 作業フォルダに画像を書くか。
        var writeImages = true
        /// `$CODEX_HOME/generated_images/<thread_id>/` にも画像を書くか（CODEX_HOME が空なら書かない）。
        var writeToCodexHome = false
        /// 画像を書く前に待つ秒数。
        var delaySeconds: Double = 0
        /// 終了コード。
        var exitCode: Int32 = 0
        /// 非 nil なら `{"type":"error"}` と `{"type":"turn.failed"}` を出す（stderr にも出す）。
        var errorMessage: String?
        /// stderr に出す行。
        var stderrLines: [String] = []
        /// スレッド ID。nil なら毎回作る。
        var threadId: String?
        /// `-o` のファイルを書くか。
        var writeLastMessage = true

        static let success = Behavior()
        static let noImages = Behavior(writeImages: false)
        static let generatedOnly = Behavior(writeImages: false, writeToCodexHome: true)
        static func slow(_ seconds: Double) -> Behavior { Behavior(delaySeconds: seconds) }
        static func failure(_ message: String = "something went wrong", exitCode: Int32 = 1) -> Behavior {
            Behavior(writeImages: false, exitCode: exitCode, errorMessage: message, writeLastMessage: false)
        }
        static let rateLimited = failure("exceeded retry limit, last status: 429 Too Many Requests")
    }

    /// `directory/name` にスクリプトを書いて URL を返す。
    @discardableResult
    static func make(in directory: URL, behavior: Behavior = .success, name: String = "codex") throws -> URL {
        try ProcScript.write(script(behavior), name: name, in: directory)
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func script(_ b: Behavior) -> String {
        let q = ShellQuote.quote
        var lines: [String] = [
            "# ダミー codex（テスト用）",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH",
            "trap 'exit 130' INT TERM",
            "if [ -n \"$PROC_DUMMY_ARGS_FILE\" ]; then : > \"$PROC_DUMMY_ARGS_FILE\"; for a in \"$@\"; do printf '%s\\n' \"$a\" >> \"$PROC_DUMMY_ARGS_FILE\"; done; fi",
            "dir=.; out=; prompt=",
            "while [ $# -gt 0 ]; do",
            "  case \"$1\" in",
            "    -C|--cd) dir=\"$2\"; shift 2 ;;",
            "    -o|--output-last-message) out=\"$2\"; shift 2 ;;",
            "    -s|--sandbox|-m|--model|-c|--config|-i|--image|-p|--profile) shift 2 ;;",
            "    --) shift; prompt=\"$1\"; break ;;",
            "    *) shift ;;",
            "  esac",
            "done",
            "cd \"$dir\" || { echo \"cannot cd to $dir\" >&2; exit 2; }",
        ]
        if let threadId = b.threadId {
            lines.append("thread=\(q(threadId))")
        } else {
            lines.append("thread=$(/usr/bin/uuidgen | /usr/bin/tr 'A-Z' 'a-z')")
        }
        lines.append("printf '{\"type\":\"thread.started\",\"thread_id\":\"%s\"}\\n' \"$thread\"")
        lines.append("printf '%s\\n' \(q(json(["type": "turn.started"])))")
        for line in b.stderrLines {
            lines.append("printf '%s\\n' \(q(line)) >&2")
        }
        if b.delaySeconds > 0 {
            lines.append("sleep \(b.delaySeconds) & wait $!")
        }
        if let names = b.imageNames {
            lines.append("names=\(q(names.joined(separator: " ")))")
        } else {
            lines.append("names=$(printf '%s' \"$prompt\" | grep -o '`[^`]*\\.png`' | tr -d '`' | tr '\\n' ' ')")
            lines.append("[ -n \"$names\" ] || names=test-01.png")
        }
        lines.append("png=\(q(pngBase64))")
        if b.writeImages {
            lines.append("for n in $names; do printf '%s' \"$png\" | base64 -D > \"$n\"; done")
            let item = json(["type": "item.completed", "item": ["id": "item_1", "type": "command_execution", "command": "cp generated.png", "exit_code": 0, "aggregated_output": ""]])
            lines.append("printf '%s\\n' \(q(item))")
        }
        if b.writeToCodexHome {
            lines.append("if [ -n \"$CODEX_HOME\" ]; then gdir=\"$CODEX_HOME/generated_images/$thread\"; mkdir -p \"$gdir\"; i=0; for n in $names; do i=$((i+1)); printf '%s' \"$png\" | base64 -D > \"$gdir/exec-$i.png\"; done; fi")
        }
        if let message = b.errorMessage {
            lines.append("printf '%s\\n' \(q(json(["type": "error", "message": message])))")
            lines.append("printf '%s\\n' \(q(json(["type": "turn.failed", "error": ["message": message]])))")
            lines.append("printf 'ERROR: %s\\n' \(q(message)) >&2")
        } else {
            lines.append("text=$(printf '%s\\n' $names)")
            lines.append("printf '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_2\",\"type\":\"agent_message\",\"text\":\"%s\"}}\\n' \"$(printf '%s' \"$text\" | tr '\\n' ' ')\"")
            lines.append("printf '%s\\n' \(q(json(["type": "turn.completed", "usage": ["input_tokens": 10, "output_tokens": 5]])))")
        }
        if b.writeLastMessage {
            lines.append("if [ -n \"$out\" ]; then printf '%s\\n' $names > \"$out\"; fi")
        }
        lines.append("exit \(b.exitCode)")
        return lines.joined(separator: "\n")
    }
}

// MARK: - 行分け

@Suite("ProcessSupportLineSplitter")
struct ProcLineSplitterTests {
    @Test func splitsAcrossChunksAndKeepsPartialLines() {
        var s = ProcessSupportLineSplitter()
        #expect(s.append(Array("ab".utf8)) == [])
        #expect(s.append(Array("c\nde".utf8)) == ["abc"])
        #expect(s.append(Array("\n\nf\r\n".utf8)) == ["de", "", "f"])
        #expect(s.finish() == nil)
        #expect(s.append(Array("tail".utf8)) == [])
        #expect(s.finish() == "tail")
        #expect(s.finish() == nil)
    }

    @Test func multiByteCharacterSplitAcrossChunks() {
        let bytes = Array("日本語\n".utf8)
        var s = ProcessSupportLineSplitter()
        var lines: [String] = []
        for b in bytes {
            lines += s.append([b])
        }
        #expect(lines == ["日本語"])
    }

    @Test func stripsOnlyOneTrailingCarriageReturn() {
        var s = ProcessSupportLineSplitter()
        #expect(s.append(Array("a\r\r\nb\rc\n".utf8)) == ["a\r", "b\rc"])
        #expect(s.append(Array("x\r".utf8)) == [])
        #expect(s.finish() == "x")
    }

    @Test func invalidUTF8IsDecodedLossily() {
        var s = ProcessSupportLineSplitter()
        let lines = s.append([0x61, 0xFF, 0x62, 0x0A])
        #expect(lines == ["a\u{FFFD}b"])
    }
}

// MARK: - ProcessCodexRunner

@Suite("ProcessCodexRunner")
struct ProcessRunnerTests {
    let runner = ProcessCodexRunner(killGracePeriod: 0.5)

    @Test func streamsLinesInOrderBeforeReturning() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let script = try ProcScript.write(#"""
        echo "out-1"
        echo "err-1" >&2
        echo "out-2"
        printf 'out-3\r\n'
        head -c 51200 /dev/zero | tr '\0' 'x'; echo
        echo "err-2" >&2
        printf '\346\227'; sleep 0.15; printf '\245\346\234\254'; sleep 0.15; printf '\350\252\236\n'
        echo "out-5"
        printf 'err-last' >&2
        printf 'last-no-newline'
        """#, in: tmp.url)
        let collector = ProcLineCollector()
        let outcome = try await runner.run(procInvocation(script, workingDirectory: tmp.url), onLine: collector.onLine)

        #expect(outcome == ProcessOutcome(exitCode: 0))
        #expect(collector.lines(.stdout) == [
            "out-1", "out-2", "out-3", String(repeating: "x", count: 51200), "日本語", "out-5", "last-no-newline",
        ])
        #expect(collector.lines(.stderr) == ["err-1", "err-2", "err-last"])
    }

    @Test func largeOutputIsFullyDrained() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let script = try ProcScript.write("seq 1 100000; seq 1 20000 >&2", in: tmp.url)
        let collector = ProcLineCollector()
        let outcome = try await runner.run(procInvocation(script, workingDirectory: tmp.url), onLine: collector.onLine)
        #expect(outcome.exitCode == 0)
        let out = collector.lines(.stdout)
        #expect(out.count == 100_000)
        #expect(out.first == "1")
        #expect(out.last == "100000")
        #expect(collector.lines(.stderr).count == 20_000)
    }

    /// 終了通知が最後の出力より先に届いても取りこぼさないこと（短いプロセスを何度も）。
    @Test func shortRunsNeverLoseTrailingOutput() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        for i in 0..<25 {
            let collector = ProcLineCollector()
            let inv = procInvocation(
                URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'a\\nb\\nlast-\(i)'; printf 'e1\\ne-\(i)' >&2"],
                workingDirectory: tmp.url
            )
            _ = try await runner.run(inv, onLine: collector.onLine)
            #expect(collector.lines(.stdout) == ["a", "b", "last-\(i)"])
            #expect(collector.lines(.stderr) == ["e1", "e-\(i)"])
        }
    }

    @Test func exitCodeIsPropagated() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let script = try ProcScript.write("echo bye; exit 3", in: tmp.url)
        let outcome = try await runner.run(procInvocation(script, workingDirectory: tmp.url), onLine: { _, _ in })
        #expect(outcome == ProcessOutcome(exitCode: 3, terminatedBySignal: false, cancelled: false, timedOut: false))
    }

    @Test func signalTerminationIsReported() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let script = try ProcScript.write("echo before; kill -TERM $$; sleep 5", in: tmp.url)
        let collector = ProcLineCollector()
        let outcome = try await runner.run(procInvocation(script, workingDirectory: tmp.url), onLine: collector.onLine)
        #expect(outcome.terminatedBySignal)
        #expect(outcome.exitCode == SIGTERM)
        #expect(!outcome.cancelled)
        #expect(!outcome.timedOut)
        #expect(collector.lines(.stdout) == ["before"])
    }

    @Test func stdinIsDevNull() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let script = try ProcScript.write(#"""
        if [ -t 0 ]; then echo "stdin=tty"; fi
        data=$(cat)
        echo "read=[$data]"
        if [ "$(stat -L -f '%Z' /dev/stdin)" = "$(stat -f '%Z' /dev/null)" ]; then echo "stdin=devnull"; fi
        """#, in: tmp.url)
        let collector = ProcLineCollector()
        let started = Date()
        let outcome = try await runner.run(procInvocation(script, workingDirectory: tmp.url, timeout: 5), onLine: collector.onLine)
        #expect(Date().timeIntervalSince(started) < 4)
        #expect(!outcome.timedOut)
        #expect(collector.lines(.stdout) == ["read=[]", "stdin=devnull"])
    }

    @Test func environmentAndWorkingDirectoryAreApplied() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let work = try tmp.subdirectory("作業 フォルダ")
        let home = try tmp.subdirectory("home")
        let script = try ProcScript.write(#"""
        echo "HOME=$HOME"
        echo "FOO=$FOO"
        echo "PWD=$(pwd -P)"
        echo "XCT=${XCTestConfigurationFilePath-unset}"
        """#, in: tmp.url)
        let env = ["HOME": home.path, "FOO": "bar baz 日本", "PATH": "/usr/bin:/bin"]
        let collector = ProcLineCollector()
        _ = try await runner.run(procInvocation(script, workingDirectory: work, environment: env), onLine: collector.onLine)
        #expect(collector.lines(.stdout) == [
            "HOME=\(home.path)",
            "FOO=bar baz 日本",
            "PWD=\(ProcPath.real(work))",
            "XCT=unset",
        ])
    }

    @Test func cancellationSendsSIGINTAndCleansUpChildren() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let script = try ProcScript.write(#"""
        trap 'echo got-int; exit 130' INT
        sleep 30 &
        echo "child=$!"
        echo ready
        wait
        """#, in: tmp.url)
        let collector = ProcLineCollector()
        let inv = procInvocation(script, workingDirectory: tmp.url)
        let runner = self.runner
        let task = Task { try await runner.run(inv, onLine: collector.onLine) }
        #expect(await collector.waitUntil { $0.contains(.stdout, "ready") })
        let child = try #require(collector.pid(after: "child="))

        let cancelledAt = Date()
        task.cancel()
        let outcome = try await task.value
        let elapsed = Date().timeIntervalSince(cancelledAt)

        #expect(outcome.cancelled)
        #expect(!outcome.timedOut)
        #expect(outcome.exitCode == 130)
        #expect(!outcome.terminatedBySignal)
        #expect(elapsed < 2)
        #expect(collector.contains(.stdout, "got-int"))
        #expect(await ProcWait.untilGone(child), "子の sleep が残っている")
    }

    @Test func cancellationEscalatesToSIGKILLWhenINTIsIgnored() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let script = try ProcScript.write(#"""
        trap '' INT
        sleep 30 &
        echo "child=$!"
        /bin/sh -c 'sleep 30 & echo "grandchild=$!"; wait' &
        sleep 0.1
        echo ready
        wait
        """#, in: tmp.url)
        let collector = ProcLineCollector()
        let inv = procInvocation(script, workingDirectory: tmp.url)
        let runner = self.runner
        let task = Task { try await runner.run(inv, onLine: collector.onLine) }
        #expect(await collector.waitUntil { $0.contains(.stdout, "ready") && $0.pid(after: "grandchild=") != nil })
        let child = try #require(collector.pid(after: "child="))
        let grandchild = try #require(collector.pid(after: "grandchild="))

        let cancelledAt = Date()
        task.cancel()
        let outcome = try await task.value
        let elapsed = Date().timeIntervalSince(cancelledAt)

        #expect(outcome.cancelled)
        #expect(outcome.terminatedBySignal)
        #expect(outcome.exitCode == SIGKILL)
        #expect(elapsed >= 0.4)
        #expect(elapsed < 2)
        #expect(await ProcWait.untilGone(child), "子の sleep が残っている")
        #expect(await ProcWait.untilGone(grandchild), "孫の sleep が残っている")
    }

    @Test func defaultKillGracePeriodIsThreeSeconds() {
        // 要件: 中止はサブプロセスへ SIGINT → 3 秒後 SIGKILL。本番は既定値のまま `ProcessCodexRunner()` を使う。
        #expect(ProcessCodexRunner().killGracePeriod == 3)
        #expect(ProcessCodexRunner(killGracePeriod: 0.5).killGracePeriod == 0.5)
    }

    @Test func defaultRunnerKillsAProcessIgnoringSIGINTAfterAboutThreeSeconds() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let script = try ProcScript.write(#"""
        trap '' INT
        sleep 30 &
        echo "child=$!"
        echo ready
        wait
        """#, in: tmp.url)
        let collector = ProcLineCollector()
        let inv = procInvocation(script, workingDirectory: tmp.url)
        let runner = ProcessCodexRunner()
        let task = Task { try await runner.run(inv, onLine: collector.onLine) }
        #expect(await collector.waitUntil { $0.contains(.stdout, "ready") })
        let child = try #require(collector.pid(after: "child="))

        let cancelledAt = Date()
        task.cancel()
        let outcome = try await task.value
        let elapsed = Date().timeIntervalSince(cancelledAt)

        #expect(outcome.cancelled)
        #expect(outcome.terminatedBySignal)
        #expect(outcome.exitCode == SIGKILL)
        #expect(elapsed >= 2.5, "SIGINT から SIGKILL まで 3 秒待つ（\(elapsed) 秒）")
        #expect(elapsed < 5, "3 秒の猶予のあとすぐに SIGKILL する（\(elapsed) 秒）")
        #expect(await ProcWait.untilGone(child), "子の sleep が残っている")
    }

    @Test func returnsAfterDrainTimeoutWhenAGrandchildHoldsThePipe() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let script = try ProcScript.write(#"""
        echo before
        sleep 30 &
        echo "child=$!"
        exit 0
        """#, in: tmp.url)
        var runner = ProcessCodexRunner(killGracePeriod: 0.5)
        runner.drainTimeout = 0.5
        let collector = ProcLineCollector()
        let started = Date()
        let outcome = try await runner.run(procInvocation(script, workingDirectory: tmp.url), onLine: collector.onLine)
        let elapsed = Date().timeIntervalSince(started)
        if let child = collector.pid(after: "child=") {
            ProcessSupportProcessTree.send(SIGKILL, to: child)
        }
        #expect(outcome == ProcessOutcome(exitCode: 0))
        #expect(elapsed >= 0.4)
        #expect(elapsed < 2.5)
        #expect(collector.lines(.stdout).first == "before")
        #expect(collector.pid(after: "child=") != nil)
    }

    @Test func cancelWhileWaitingForPipeKillsTheLeftoverChild() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let script = try ProcScript.write(#"""
        sleep 30 &
        echo "child=$!"
        exit 0
        """#, in: tmp.url)
        var runner = ProcessCodexRunner(killGracePeriod: 0.5)
        runner.drainTimeout = 20
        let collector = ProcLineCollector()
        let inv = procInvocation(script, workingDirectory: tmp.url)
        let task = Task { [runner] in try await runner.run(inv, onLine: collector.onLine) }
        #expect(await collector.waitUntil { $0.pid(after: "child=") != nil })
        let child = try #require(collector.pid(after: "child="))
        try? await Task.sleep(nanoseconds: 300_000_000)
        let cancelledAt = Date()
        task.cancel()
        let outcome = try await task.value
        #expect(Date().timeIntervalSince(cancelledAt) < 2)
        #expect(outcome.cancelled)
        #expect(outcome.exitCode == 0)
        #expect(await ProcWait.untilGone(child), "子の sleep が残っている")
    }

    @Test func timeoutStopsTheProcess() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let script = try ProcScript.write("echo start; sleep 30 & wait", in: tmp.url)
        let collector = ProcLineCollector()
        let started = Date()
        let outcome = try await runner.run(
            procInvocation(script, workingDirectory: tmp.url, timeout: 0.5),
            onLine: collector.onLine
        )
        let elapsed = Date().timeIntervalSince(started)
        #expect(outcome.timedOut)
        #expect(!outcome.cancelled)
        #expect(elapsed >= 0.4)
        #expect(elapsed < 2.5)
        #expect(collector.lines(.stdout) == ["start"])
    }

    @Test func timeoutEscalatesWhenINTIsIgnored() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let script = try ProcScript.write("trap '' INT; sleep 30 & wait", in: tmp.url)
        let started = Date()
        // 負荷が高いと sh が trap を入れる前に SIGINT が届くことがあるので、タイムアウトは 1 秒取る。
        let outcome = try await runner.run(procInvocation(script, workingDirectory: tmp.url, timeout: 1.0), onLine: { _, _ in })
        let elapsed = Date().timeIntervalSince(started)
        #expect(outcome.timedOut)
        #expect(outcome.terminatedBySignal)
        #expect(outcome.exitCode == SIGKILL)
        #expect(elapsed < 3.5)
    }

    @Test func alreadyCancelledTaskDoesNotLaunch() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let marker = tmp.url.appendingPathComponent("launched")
        let script = try ProcScript.write("touch \(ShellQuote.quote(marker.path))", in: tmp.url)
        let inv = procInvocation(script, workingDirectory: tmp.url)
        let runner = self.runner
        let task = Task { () async throws -> ProcessOutcome in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return try await runner.run(inv, onLine: { _, _ in })
        }
        task.cancel()
        let outcome = try await task.value
        #expect(outcome.cancelled)
        #expect(outcome.exitCode == -1)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func launchFailureThrows() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let missing = tmp.url.appendingPathComponent("no-such-codex")
        await #expect(throws: CodexRunnerError.self) {
            try await runner.run(procInvocation(missing, workingDirectory: tmp.url), onLine: { _, _ in })
        }

        let notExecutable = tmp.url.appendingPathComponent("plain.txt")
        try "echo hi\n".write(to: notExecutable, atomically: true, encoding: .utf8)
        await #expect(throws: CodexRunnerError.self) {
            try await runner.run(procInvocation(notExecutable, workingDirectory: tmp.url), onLine: { _, _ in })
        }

        await #expect(throws: CodexRunnerError.self) {
            try await runner.run(procInvocation(tmp.url, workingDirectory: tmp.url), onLine: { _, _ in })
        }

        let script = try ProcScript.write("echo hi", in: tmp.url)
        let noDir = tmp.url.appendingPathComponent("missing-dir", isDirectory: true)
        let error = await #expect(throws: CodexRunnerError.self) {
            try await runner.run(procInvocation(script, workingDirectory: noDir), onLine: { _, _ in })
        }
        if case .launchFailed(let message)? = error {
            #expect(!message.isEmpty)
        }
    }

    @Test func manyRunsInParallel() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let script = try ProcScript.write(#"""
        i=1
        while [ $i -le 40 ]; do
          echo "job-$1-line-$i"
          if [ $((i % 10)) -eq 0 ]; then echo "job-$1-err-$i" >&2; sleep 0.02; fi
          i=$((i + 1))
        done
        printf "job-$1-end"
        exit $1
        """#, in: tmp.url)
        let runner = self.runner
        let results = try await withThrowingTaskGroup(of: (Int, ProcessOutcome, [String], [String]).self) { group in
            for n in 1...6 {
                group.addTask {
                    let collector = ProcLineCollector()
                    let inv = procInvocation(script, arguments: ["\(n)"], workingDirectory: tmp.url)
                    let outcome = try await runner.run(inv, onLine: collector.onLine)
                    return (n, outcome, collector.lines(.stdout), collector.lines(.stderr))
                }
            }
            var all: [(Int, ProcessOutcome, [String], [String])] = []
            for try await r in group {
                all.append(r)
            }
            return all
        }
        #expect(results.count == 6)
        for (n, outcome, out, err) in results {
            #expect(outcome.exitCode == Int32(n))
            #expect(out == (1...40).map { "job-\(n)-line-\($0)" } + ["job-\(n)-end"])
            #expect(err == [10, 20, 30, 40].map { "job-\(n)-err-\($0)" })
        }
    }

    // MARK: ダミー codex

    @Test func dummyCodexWritesImageThroughRunner() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let codex = try ProcDummyCodex.make(in: tmp.url)
        let runDir = try tmp.subdirectory("20261024-153012-test")
        let job = JobRecord(createdAt: Date(), slug: "test", prompt: "猫のステッカー", preset: "", count: 1, aspect: .square, background: .transparent)
        let options = CommandBuilder.Options(
            codexPath: codex.path,
            workingDirectory: runDir.path,
            prompt: PromptBuilder.fullPrompt(for: job, template: AppSettings.defaultInstructionTemplate)
        )
        let argsFile = tmp.url.appendingPathComponent("args.txt")
        var env = ProcEnv.minimal
        env["PROC_DUMMY_ARGS_FILE"] = argsFile.path
        let collector = ProcLineCollector()
        let outcome = try await runner.run(
            procInvocation(codex, arguments: CommandBuilder.arguments(options), workingDirectory: runDir, environment: env),
            onLine: collector.onLine
        )

        #expect(outcome == ProcessOutcome(exitCode: 0))
        let png = runDir.appendingPathComponent("test-01.png")
        let data = try Data(contentsOf: png)
        #expect(ImageDetector.sniffExtension(data) == "png")
        #expect(ImageDetector.newImages(before: [], directory: runDir) == ["test-01.png"])

        let lastMessage = try String(contentsOf: runDir.appendingPathComponent(CommandBuilder.lastMessageFileName), encoding: .utf8)
        #expect(ImageDetector.fileNamesListed(in: lastMessage) == ["test-01.png"])

        let stdout = collector.lines(.stdout)
        #expect(stdout.compactMap(ImageDetector.threadId(fromJSONLLine:)).count == 1)
        for line in stdout {
            #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil, "JSONL ではない行: \(line)")
        }
        #expect(stdout.contains { $0.contains("\"turn.completed\"") })

        let args = try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        #expect(args.first == "exec")
        #expect(args.contains("--"))
    }

    @Test func dummyCodexTakesNamesFromPromptAndHandlesReferenceImages() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let codex = try ProcDummyCodex.make(in: tmp.url)
        let runDir = try tmp.subdirectory("run")
        let ref = tmp.url.appendingPathComponent("ref image.png")
        try ProcDummyCodex.pngData.write(to: ref)
        let job = JobRecord(createdAt: Date(), slug: "kina-mascot", prompt: "マスコット", preset: "", count: 2, aspect: .landscape, background: .white)
        let options = CommandBuilder.Options(
            codexPath: codex.path,
            workingDirectory: runDir.path,
            prompt: PromptBuilder.fullPrompt(for: job, template: AppSettings.defaultInstructionTemplate),
            referenceImages: [ref.path],
            model: "gpt-x",
            reasoningEffort: .low,
            ephemeral: true
        )
        let outcome = try await runner.run(
            procInvocation(codex, arguments: CommandBuilder.arguments(options), workingDirectory: runDir),
            onLine: { _, _ in }
        )
        #expect(outcome.exitCode == 0)
        #expect(ImageDetector.newImages(before: [], directory: runDir) == ["kina-mascot-01.png", "kina-mascot-02.png"])
    }

    @Test func dummyCodexFailureAndRateLimit() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let codex = try ProcDummyCodex.make(in: tmp.url, behavior: .rateLimited)
        let runDir = try tmp.subdirectory("run")
        let options = CommandBuilder.Options(codexPath: codex.path, workingDirectory: runDir.path, prompt: "x")
        let collector = ProcLineCollector()
        let outcome = try await runner.run(
            procInvocation(codex, arguments: CommandBuilder.arguments(options), workingDirectory: runDir),
            onLine: collector.onLine
        )
        #expect(outcome.exitCode == 1)
        #expect(ImageDetector.newImages(before: [], directory: runDir).isEmpty)
        #expect(collector.all.contains { RateLimitDetector.isRateLimited(stream: $0.0, line: $0.1) })
        #expect(collector.lines(.stdout).compactMap(JSONLLog.errorMessage(line:)).count == 2)
    }

    @Test func dummyCodexCanBeCancelledWhileSlow() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let codex = try ProcDummyCodex.make(in: tmp.url, behavior: .slow(30))
        let runDir = try tmp.subdirectory("run")
        let options = CommandBuilder.Options(codexPath: codex.path, workingDirectory: runDir.path, prompt: "x")
        let collector = ProcLineCollector()
        let inv = procInvocation(codex, arguments: CommandBuilder.arguments(options), workingDirectory: runDir)
        let runner = self.runner
        let task = Task { try await runner.run(inv, onLine: collector.onLine) }
        #expect(await collector.waitUntil { $0.lines(.stdout).count >= 2 })
        task.cancel()
        let outcome = try await task.value
        #expect(outcome.cancelled)
        #expect(outcome.exitCode == 130)
        #expect(ImageDetector.newImages(before: [], directory: runDir).isEmpty)
    }

    @Test func dummyCodexGeneratedOnlyWritesToCodexHome() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let codexHome = try tmp.subdirectory("codex-home")
        let codex = try ProcDummyCodex.make(in: tmp.url, behavior: .generatedOnly)
        let runDir = try tmp.subdirectory("run")
        let options = CommandBuilder.Options(codexPath: codex.path, workingDirectory: runDir.path, prompt: "`a-01.png`")
        var env = ProcEnv.minimal
        env["CODEX_HOME"] = codexHome.path
        let collector = ProcLineCollector()
        _ = try await runner.run(
            procInvocation(codex, arguments: CommandBuilder.arguments(options), workingDirectory: runDir, environment: env),
            onLine: collector.onLine
        )
        #expect(ImageDetector.newImages(before: [], directory: runDir).isEmpty)
        let threadId = try #require(collector.lines(.stdout).compactMap(ImageDetector.threadId(fromJSONLLine:)).first)
        #expect(ImageDetector.generatedImages(codexHome: codexHome, threadId: threadId).count == 1)
    }
}

// MARK: - プロセス表

@Suite("ProcessSupportProcessTree")
struct ProcProcessTreeTests {
    @Test func findsDescendantsOfALaunchedProcess() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 5 & sleep 5 & wait"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        defer {
            ProcessSupportProcessTree.signalIfStillRunning(ProcessSupportProcessTree.descendants(of: p.processIdentifier), signal: SIGKILL)
            p.terminate()
        }
        var found: [ProcessSupportProcessTree.Entry] = []
        for _ in 0..<100 {
            found = ProcessSupportProcessTree.descendants(of: p.processIdentifier)
            if found.count >= 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.parentPid == p.processIdentifier })
        // Process は子を新しいプロセスグループのリーダーにする。
        #expect(getpgid(p.processIdentifier) == p.processIdentifier)
        #expect(ProcessSupportProcessTree.descendants(of: getpid()).contains { $0.pid == p.processIdentifier })
    }

    @Test func refusesDangerousTargets() {
        #expect(!ProcessSupportProcessTree.send(0, to: 0))
        #expect(!ProcessSupportProcessTree.send(0, to: 1))
        #expect(!ProcessSupportProcessTree.send(0, to: -1))
        #expect(!ProcessSupportProcessTree.send(0, to: getpid()))
        #expect(!ProcessSupportProcessTree.sendToGroup(0, groupId: getpgrp()))
        #expect(!ProcessSupportProcessTree.sendToGroup(0, groupId: 0))
        #expect(ProcessSupportProcessTree.descendants(of: 0).isEmpty)
        #expect(ProcessSupportProcessTree.descendants(of: 1).isEmpty)
    }

    @Test func pidReuseIsDetectedByStartTime() throws {
        let me = try #require(ProcessSupportProcessTree.entry(for: getpid()))
        var other = me
        other.startSeconds -= 1
        #expect(me.isSameProcess(as: me))
        #expect(!me.isSameProcess(as: other))
        #expect(ProcessSupportProcessTree.isRunning(getpid()))
    }
}
