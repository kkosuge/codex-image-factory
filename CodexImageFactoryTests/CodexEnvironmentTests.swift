import Foundation
import Synchronization
import Testing
@testable import CodexImageFactory

@Suite("CodexEnvironment.processEnvironment")
struct ProcEnvironmentBuildTests {
    @Test func homeIsAddedWhenMissingOrEmpty() {
        let missing = CodexEnvironment.processEnvironment(base: ["PATH": "/usr/bin"], loginShellPath: nil)
        #expect(missing["HOME"] == NSHomeDirectory())
        let empty = CodexEnvironment.processEnvironment(base: ["HOME": "", "PATH": "/usr/bin"], loginShellPath: nil)
        #expect(empty["HOME"] == NSHomeDirectory())
    }

    @Test func existingHomeIsKept() {
        let env = CodexEnvironment.processEnvironment(base: ["HOME": "/Users/someone"], loginShellPath: "/a:/b")
        #expect(env["HOME"] == "/Users/someone")
    }

    @Test func loginShellPathWins() {
        let env = CodexEnvironment.processEnvironment(
            base: ["PATH": "/usr/bin:/bin"],
            loginShellPath: "/Users/a/.local/share/mise/installs/codex/latest/bin:/usr/bin:/bin\n"
        )
        #expect(env["PATH"] == "/Users/a/.local/share/mise/installs/codex/latest/bin:/usr/bin:/bin")
    }

    @Test func fallbackPathAddsStandardDirectories() {
        let env = CodexEnvironment.processEnvironment(base: ["HOME": "/Users/x", "PATH": "/custom/bin:/usr/bin:/bin"], loginShellPath: nil)
        let entries = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        #expect(entries.first == "/custom/bin")
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/Users/x/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
            #expect(entries.contains(dir), "\(dir) がない")
        }
        #expect(Set(entries).count == entries.count, "重複がある")

        let blank = CodexEnvironment.processEnvironment(base: ["HOME": "/Users/x"], loginShellPath: "  ")
        #expect(blank["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/Users/x/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func junkVariablesAreRemovedAndOthersKept() {
        let base = [
            "HOME": "/Users/x",
            "PATH": "/usr/bin",
            "XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration",
            "XCTestBundlePath": "/tmp/x.xctest",
            "XCTestSessionIdentifier": "abc",
            "XCInjectBundleInto": "/x",
            "__XPC_DYLD_LIBRARY_PATH": "/x",
            "__XCODE_BUILT_PRODUCTS_DIR_PATHS": "/x",
            "DYLD_INSERT_LIBRARIES": "/x.dylib",
            "DYLD_FRAMEWORK_PATH": "/x",
            "MallocStackLogging": "1",
            "MallocStackLoggingNoCompact": "1",
            "OS_ACTIVITY_DT_MODE": "YES",
            "NSUnbufferedIO": "YES",
            "CODEX_HOME": "/Users/x/.codex-alt",
            "LANG": "ja_JP.UTF-8",
            "FOO": "bar",
        ]
        let env = CodexEnvironment.processEnvironment(base: base, loginShellPath: nil)
        #expect(env.keys.filter { $0.hasPrefix("XC") || $0.hasPrefix("DYLD_") || $0.hasPrefix("__X") || $0.hasPrefix("Malloc") }.isEmpty)
        #expect(env["OS_ACTIVITY_DT_MODE"] == nil)
        #expect(env["NSUnbufferedIO"] == nil)
        #expect(env["CODEX_HOME"] == "/Users/x/.codex-alt")
        #expect(env["LANG"] == "ja_JP.UTF-8")
        #expect(env["FOO"] == "bar")
        #expect(env["HOME"] == "/Users/x")
    }

    @Test func defaultBaseIsTheAppEnvironmentWithoutTestVariables() {
        let env = CodexEnvironment.processEnvironment(loginShellPath: nil)
        #expect(env["HOME"]?.isEmpty == false)
        #expect(env["PATH"]?.contains("/usr/bin") == true)
        #expect(env["XCTestConfigurationFilePath"] == nil)
        #expect(env.keys.allSatisfy { !$0.hasPrefix("DYLD_") })
    }
}

@Suite("CodexEnvironment 下請け")
struct ProcEnvironmentHelperTests {
    @Test func markedValueIsExtractedFromNoisyOutput() {
        let b = CodexEnvironment.markerBegin
        let e = CodexEnvironment.markerEnd
        #expect(CodexEnvironment.extractMarkedValue("\(b)/usr/bin/codex\(e)") == "/usr/bin/codex")
        #expect(CodexEnvironment.extractMarkedValue("Welcome!\n\u{1B}[1mbanner\u{1B}[0m\n\(b) /a/b \n\(e)\nbye") == "/a/b")
        #expect(CodexEnvironment.extractMarkedValue("\(b)\(e)") == nil)
        #expect(CodexEnvironment.extractMarkedValue("no markers") == nil)
        #expect(CodexEnvironment.extractMarkedValue("\(b)/only/begin") == nil)
    }

    @Test func choosePathPrefersTheLongerInteractivePath() {
        #expect(CodexEnvironment.choosePath(login: "/usr/bin:/bin", interactive: "/mise/bin:/usr/bin:/bin") == "/mise/bin:/usr/bin:/bin")
        #expect(CodexEnvironment.choosePath(login: "/usr/bin:/bin", interactive: "/bin:/usr/bin") == "/usr/bin:/bin")
        #expect(CodexEnvironment.choosePath(login: "/usr/bin:/bin", interactive: nil) == "/usr/bin:/bin")
        #expect(CodexEnvironment.choosePath(login: nil, interactive: "/x:/x:/y") == "/x:/y")
        #expect(CodexEnvironment.choosePath(login: nil, interactive: nil) == nil)
        #expect(CodexEnvironment.choosePath(login: "", interactive: ":") == nil)
    }

    @Test func wellKnownPathsKeepTheMiseLatestSymlink() {
        let paths = CodexEnvironment.wellKnownCodexPaths(home: "/Users/x")
        #expect(paths.first == "/Users/x/.local/share/mise/installs/codex/latest/bin/codex")
        #expect(paths.contains("/opt/homebrew/bin/codex"))
        #expect(paths.contains("/Users/x/.bun/bin/codex"))
    }

    @Test func executablePathRejectsNonPaths() throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let script = try ProcScript.write("exit 0", name: "codex", in: tmp.url)
        #expect(CodexEnvironment.executablePath(" \(script.path)\n") == script.path)
        #expect(CodexEnvironment.executablePath("alias codex='npx codex'") == nil)
        #expect(CodexEnvironment.executablePath("codex") == nil)
        #expect(CodexEnvironment.executablePath(tmp.url.path) == nil)
        #expect(CodexEnvironment.executablePath(tmp.url.appendingPathComponent("missing").path) == nil)
    }

    @Test func loggedInJudgement() {
        #expect(CodexEnvironment.isLoggedIn(exitCode: 0, output: "Logged in using ChatGPT"))
        #expect(!CodexEnvironment.isLoggedIn(exitCode: 1, output: "Not logged in"))
        #expect(!CodexEnvironment.isLoggedIn(exitCode: 0, output: "NOT LOGGED IN"))
        #expect(!CodexEnvironment.isLoggedIn(exitCode: 1, output: "Logged in using ChatGPT"))
    }
}

@Suite("CodexEnvironment コマンド実行")
struct ProcEnvironmentCommandTests {
    @Test func runCaptureMergesStdoutAndStderr() async throws {
        let r = try #require(await CodexEnvironment.runCapture(
            executable: "/bin/sh",
            arguments: ["-c", "echo one; echo two >&2; printf 'three'; exit 4"],
            environment: ProcEnv.minimal,
            timeout: 5
        ))
        #expect(r.exitCode == 4)
        #expect(r.output == "one\ntwo\nthree")
    }

    @Test func runCaptureReadsNothingFromStdin() async throws {
        let r = try #require(await CodexEnvironment.runCapture(
            executable: "/bin/cat", arguments: [], environment: ProcEnv.minimal, timeout: 5
        ))
        #expect(r.exitCode == 0)
        #expect(r.output.isEmpty)
    }

    @Test func runCaptureReturnsNilWhenItCannotLaunch() async {
        let r = await CodexEnvironment.runCapture(
            executable: "/no/such/binary", arguments: [], environment: ProcEnv.minimal, timeout: 5
        )
        #expect(r == nil)
    }

    @Test func runCaptureTimesOut() async {
        let started = Date()
        let r = await CodexEnvironment.runCapture(
            executable: "/bin/sh", arguments: ["-c", "trap '' TERM; sleep 30 & wait"], environment: ProcEnv.minimal, timeout: 0.3
        )
        #expect(r == nil)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func loginStatusLoggedIn() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let codex = try ProcScript.write(#"""
        if [ "$1 $2" = "login status" ]; then echo "Logged in using ChatGPT"; exit 0; fi
        exit 9
        """#, name: "codex", in: tmp.url)
        let status = await CodexEnvironment.loginStatus(codexPath: codex.path, environment: ProcEnv.minimal)
        #expect(status == LoginStatus(loggedIn: true, output: "Logged in using ChatGPT", exitCode: 0))
    }

    @Test func loginStatusNotLoggedIn() async throws {
        let tmp = try ProcTempDir()
        defer { tmp.remove() }
        let codex = try ProcScript.write(#"echo "Not logged in" >&2; exit 1"#, name: "codex", in: tmp.url)
        let status = await CodexEnvironment.loginStatus(codexPath: codex.path, environment: ProcEnv.minimal)
        #expect(!status.loggedIn)
        #expect(status.exitCode == 1)
        #expect(status.output == "Not logged in")

        let quiet = try ProcScript.write(#"echo "not logged in""#, name: "codex2", in: tmp.url)
        let status2 = await CodexEnvironment.loginStatus(codexPath: quiet.path, environment: ProcEnv.minimal)
        #expect(!status2.loggedIn)
        #expect(status2.exitCode == 0)
    }

    @Test func loginStatusWhenCodexCannotLaunch() async {
        let status = await CodexEnvironment.loginStatus(codexPath: "/no/such/codex", environment: ProcEnv.minimal)
        #expect(!status.loggedIn)
        #expect(status.exitCode == nil)
        #expect(status.output.contains("codex を起動できませんでした"))

        let empty = await CodexEnvironment.loginStatus(codexPath: "  ", environment: ProcEnv.minimal)
        #expect(!empty.loggedIn)
        #expect(empty.exitCode == nil)
        #expect(!empty.output.isEmpty)
    }

    /// この Mac の実際のシェル設定で解決する（見つからなくても失敗にはしない）。
    @Test func resolveCodexPathSmoke() async {
        let started = Date()
        let path = await CodexEnvironment.resolveCodexPath()
        #expect(Date().timeIntervalSince(started) < 25)
        if let path {
            #expect(path.hasPrefix("/"))
            #expect(FileManager.default.isExecutableFile(atPath: path))
        } else {
            withKnownIssue("この環境では codex が見つからなかった") {
                Issue.record("resolveCodexPath() == nil")
            }
        }
    }

    @Test func loginShellPathSmoke() async {
        let started = Date()
        let path = await CodexEnvironment.loginShellPath()
        #expect(Date().timeIntervalSince(started) < 25)
        if let path {
            #expect(path.split(separator: ":").contains("/usr/bin"))
            #expect(!path.contains(CodexEnvironment.markerBegin))
        } else {
            withKnownIssue("この環境ではログインシェルの PATH が取れなかった") {
                Issue.record("loginShellPath() == nil")
            }
        }
    }
}

@Suite("CodexEnvironmentCache")
struct ProcEnvironmentCacheTests {
    /// 呼ばれた回数を数える。
    final class ProcCounter: Sendable {
        private let value = Mutex(0)
        func increment() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    @Test func concurrentFirstCallsShareOneResolution() async {
        let envCalls = ProcCounter()
        let pathCalls = ProcCounter()
        let cache = CodexEnvironmentCache(
            resolveEnvironment: {
                envCalls.increment()
                try? await Task.sleep(nanoseconds: 100_000_000)
                return ["HOME": "/Users/x", "PATH": "/p"]
            },
            resolveCodexPath: {
                pathCalls.increment()
                try? await Task.sleep(nanoseconds: 100_000_000)
                return "/x/codex"
            }
        )
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    let env = await cache.environment()
                    #expect(env["PATH"] == "/p")
                    let path = await cache.detectedCodexPath()
                    #expect(path == "/x/codex")
                }
            }
        }
        #expect(envCalls.count == 1)
        #expect(pathCalls.count == 1)
    }

    @Test func nilResultIsCachedUntilInvalidate() async {
        let calls = ProcCounter()
        let cache = CodexEnvironmentCache(
            resolveEnvironment: { ["HOME": "/h"] },
            resolveCodexPath: {
                calls.increment()
                return nil
            }
        )
        #expect(await cache.detectedCodexPath() == nil)
        #expect(await cache.detectedCodexPath() == nil)
        #expect(calls.count == 1)
        await cache.invalidate()
        #expect(await cache.detectedCodexPath() == nil)
        #expect(calls.count == 2)
    }

    @Test func invalidateResolvesEnvironmentAgain() async {
        let calls = ProcCounter()
        let cache = CodexEnvironmentCache(
            resolveEnvironment: {
                calls.increment()
                return ["N": "\(calls.count)"]
            },
            resolveCodexPath: { nil }
        )
        #expect(await cache.environment()["N"] == "1")
        #expect(await cache.environment()["N"] == "1")
        await cache.invalidate()
        #expect(await cache.environment()["N"] == "2")
    }
}
