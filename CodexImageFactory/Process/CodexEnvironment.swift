import Foundation

/// `codex login status` の結果。
struct LoginStatus: Sendable, Equatable {
    var loggedIn: Bool
    /// コマンドの出力（stdout + stderr）。画面にそのまま出す。
    var output: String
    var exitCode: Int32?
}

/// codex の場所と、子プロセスに渡す環境変数を扱う。
///
/// GUI アプリはログインシェルの PATH を引き継がないので、`/bin/zsh -lc` 経由で解決する。
/// mise などを ~/.zshrc（対話シェルだけで読まれる）で有効にしている場合に備えて `-lic` も試す。
/// 見つけたパスはシンボリックリンクを解決せずにそのまま使う（mise の `latest` を `mise up` 後も使えるように）。
enum CodexEnvironment {
    static let shellPath = "/bin/zsh"
    /// シェル 1 回あたりの上限（秒）。
    static let shellTimeout: TimeInterval = 10
    /// `codex login status` の上限（秒）。
    static let loginStatusTimeout: TimeInterval = 15

    /// シェルの出力から値を取り出すための目印。起動時のバナーなどに紛れても拾えるようにする。
    static let markerBegin = "__CIF_BEGIN__"
    static let markerEnd = "__CIF_END__"

    /// 子プロセスに引き継がない環境変数の接頭辞（Xcode・テスト・デバッグ用のもの）。
    static let droppedEnvironmentPrefixes = [
        "XCTest", "XCInject", "__XPC_", "__XCODE_", "XCODE_DBG_", "DYLD_", "Malloc",
    ]
    /// 子プロセスに引き継がない環境変数。
    static let droppedEnvironmentKeys: Set<String> = [
        "OS_ACTIVITY_DT_MODE", "NSUnbufferedIO", "LLVM_PROFILE_FILE",
    ]

    /// PATH が取れなかったときに補うフォルダ（`~` はホームに展開する）。
    static let standardPathDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    /// ログインシェルで `command -v codex` を実行して絶対パスを返す。見つからなければ nil。
    ///
    /// 順に試す: 1) `zsh -lc` 2) `zsh -lic` 3) よくある置き場所。最初に見つかった実行可能ファイルを返す。
    static func resolveCodexPath() async -> String? {
        let environment = shellEnvironment()
        let expression = "$(whence -p codex 2>/dev/null || command -v codex 2>/dev/null)"
        for flags in ["-lc", "-lic"] {
            if let value = await shellValue(flags: flags, expression: expression, environment: environment),
               let path = executablePath(value) {
                return path
            }
        }
        return wellKnownCodexPaths().first(where: isExecutableFile)
    }

    /// ログインシェルの PATH。取れなければ nil。
    ///
    /// `zsh -lc` と `zsh -lic` の両方を見て、項目の多いほう（同じなら -lc）を返す。
    static func loginShellPath() async -> String? {
        let environment = shellEnvironment()
        async let login = shellValue(flags: "-lc", expression: "$PATH", environment: environment)
        async let interactive = shellValue(flags: "-lic", expression: "$PATH", environment: environment)
        let (loginValue, interactiveValue) = await (login, interactive)
        return choosePath(login: loginValue, interactive: interactiveValue)
    }

    /// 子プロセス用の環境変数。`base` に HOME（必ず）とログインシェルの PATH を足す。
    /// PATH が取れなければ `base` の PATH に `/usr/local/bin:/opt/homebrew/bin` などを補う。
    ///
    /// Xcode やテストが入れる変数（`XCTest*` `DYLD_*` `__XPC_*` `Malloc*` など）は落とす。`CODEX_HOME` などはそのまま残す。
    static func processEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        loginShellPath: String?
    ) -> [String: String] {
        var env = base.filter { !shouldDropEnvironmentKey($0.key) }
        let home: String
        if let existing = env["HOME"], !existing.isEmpty {
            home = existing
        } else {
            home = NSHomeDirectory()
            env["HOME"] = home
        }
        let loginPath = loginShellPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !loginPath.isEmpty {
            env["PATH"] = loginPath
        } else {
            env["PATH"] = fallbackPath(base: base["PATH"], home: home)
        }
        return env
    }

    /// `codex login status` を実行する。codex が起動できなければ loggedIn = false。
    static func loginStatus(codexPath: String, environment: [String: String]) async -> LoginStatus {
        let path = codexPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return LoginStatus(
                loggedIn: false,
                output: "codex が見つかりません。設定で codex のパスを指定してください。",
                exitCode: nil
            )
        }
        let result = await ProcessSupportCapture.run(
            executable: path,
            arguments: ["login", "status"],
            environment: environment,
            workingDirectory: homeDirectory(environment),
            timeout: loginStatusTimeout,
            includeStderr: true
        )
        switch result {
        case .failure(.launchFailed(let reason)):
            return LoginStatus(
                loggedIn: false,
                output: "codex を起動できませんでした（\(path)）。設定で codex のパスを確認してください。\n\(reason)",
                exitCode: nil
            )
        case .success(let output):
            let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if output.timedOut || output.cancelled {
                return LoginStatus(
                    loggedIn: false,
                    output: "codex login status が \(Int(loginStatusTimeout)) 秒以内に終わりませんでした。\n\(text)",
                    exitCode: nil
                )
            }
            return LoginStatus(
                loggedIn: isLoggedIn(exitCode: output.exitCode, output: text),
                output: text,
                exitCode: output.exitCode
            )
        }
    }

    /// 短いコマンドを実行して、終了コードと出力（stdout + stderr）を返す。起動できなければ nil。
    /// stdin は /dev/null。タイムアウトしたら止めて nil。
    static func runCapture(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) async -> (exitCode: Int32, output: String)? {
        let result = await ProcessSupportCapture.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout,
            includeStderr: true
        )
        guard case .success(let output) = result, !output.timedOut, !output.cancelled else { return nil }
        return (output.exitCode, output.text)
    }

    // MARK: - 下請け

    /// ログイン状態の判定。終了コード 0 で、出力に「Not logged in」がなければログイン済み。
    static func isLoggedIn(exitCode: Int32, output: String) -> Bool {
        exitCode == 0 && !output.lowercased().contains("not logged in")
    }

    /// よくある codex の置き場所（優先順）。シンボリックリンクは解決しない。
    static func wellKnownCodexPaths(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.local/share/mise/installs/codex/latest/bin/codex",
            "\(home)/.local/share/mise/shims/codex",
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.bun/bin/codex",
        ]
    }

    /// 実行できる通常ファイル（またはそれを指すリンク）か。
    static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// 子プロセスに引き継がない環境変数か。
    static func shouldDropEnvironmentKey(_ key: String) -> Bool {
        droppedEnvironmentKeys.contains(key) || droppedEnvironmentPrefixes.contains { key.hasPrefix($0) }
    }

    /// `base` の PATH の後ろに、足りない標準フォルダを足す（重複は除く）。
    static func fallbackPath(base: String?, home: String) -> String {
        var entries: [String] = []
        var seen: Set<String> = []
        let extra = standardPathDirectories.map { dir in
            dir.hasPrefix("~/") ? home + dir.dropFirst() : dir
        }
        for entry in (base ?? "").split(separator: ":").map(String.init) + extra
        where !entry.isEmpty && !seen.contains(entry) {
            seen.insert(entry)
            entries.append(entry)
        }
        return entries.joined(separator: ":")
    }

    /// `-lc` と `-lic` の PATH のうち、項目の多いほうを選ぶ（重複は除く）。
    static func choosePath(login: String?, interactive: String?) -> String? {
        func entries(_ value: String?) -> [String] {
            var result: [String] = []
            var seen: Set<String> = []
            for entry in (value ?? "").split(separator: ":").map(String.init) where !entry.isEmpty && !seen.contains(entry) {
                seen.insert(entry)
                result.append(entry)
            }
            return result
        }
        let loginEntries = entries(login)
        let interactiveEntries = entries(interactive)
        let chosen = interactiveEntries.count > loginEntries.count ? interactiveEntries : loginEntries
        return chosen.isEmpty ? nil : chosen.joined(separator: ":")
    }

    /// 目印で囲まれた値を取り出す（前後の空白は落とす）。見つからない・空なら nil。
    static func extractMarkedValue(_ output: String) -> String? {
        guard let begin = output.range(of: markerBegin, options: .backwards),
              let end = output.range(of: markerEnd, range: begin.upperBound..<output.endIndex) else {
            return nil
        }
        let value = output[begin.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// シェルの答えが実行可能ファイルの絶対パスならそれを返す（エイリアス定義などは捨てる）。
    static func executablePath(_ value: String) -> String? {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.contains("\n"), isExecutableFile(path) else { return nil }
        return path
    }

    /// シェルを呼ぶときの環境変数（アプリの環境から余計なものを落とし、HOME と最低限の PATH を入れる）。
    private static func shellEnvironment() -> [String: String] {
        processEnvironment(base: ProcessInfo.processInfo.environment, loginShellPath: nil)
    }

    private static func homeDirectory(_ environment: [String: String]) -> URL {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
    }

    /// `zsh <flags> -c` で式を評価し、目印の間の値を返す。stdin は /dev/null、stderr は捨てる。
    private static func shellValue(flags: String, expression: String, environment: [String: String]) async -> String? {
        let script = "printf '\(markerBegin)%s\(markerEnd)' \"\(expression)\""
        let result = await ProcessSupportCapture.run(
            executable: shellPath,
            arguments: [flags, script],
            environment: environment,
            workingDirectory: homeDirectory(environment),
            timeout: shellTimeout,
            includeStderr: false
        )
        guard case .success(let output) = result, !output.timedOut, !output.cancelled else { return nil }
        return extractMarkedValue(output.text)
    }
}

/// codex のパスと環境変数を一度だけ解決して覚えておく。
///
/// 同時に何度呼ばれてもシェルは 1 回しか起動しない（解決中の Task を共有する）。nil の結果も覚える。
actor CodexEnvironmentCache {
    static let shared = CodexEnvironmentCache()

    private let resolveEnvironment: @Sendable () async -> [String: String]
    private let resolveCodexPath: @Sendable () async -> String?
    private var environmentTask: Task<[String: String], Never>?
    private var codexPathTask: Task<String?, Never>?

    /// テストでは解決処理を差し替えられる。
    init(
        resolveEnvironment: @escaping @Sendable () async -> [String: String] = {
            let path = await CodexEnvironment.loginShellPath()
            return CodexEnvironment.processEnvironment(loginShellPath: path)
        },
        resolveCodexPath: @escaping @Sendable () async -> String? = {
            await CodexEnvironment.resolveCodexPath()
        }
    ) {
        self.resolveEnvironment = resolveEnvironment
        self.resolveCodexPath = resolveCodexPath
    }

    /// 子プロセス用の環境変数（初回はログインシェルを呼ぶ）。
    func environment() async -> [String: String] {
        if let task = environmentTask {
            return await task.value
        }
        let resolve = resolveEnvironment
        let task = Task<[String: String], Never> { await resolve() }
        environmentTask = task
        return await task.value
    }

    /// 自動検出した codex のパス（初回はログインシェルを呼ぶ）。
    func detectedCodexPath() async -> String? {
        if let task = codexPathTask {
            return await task.value
        }
        let resolve = resolveCodexPath
        let task = Task<String?, Never> { await resolve() }
        codexPathTask = task
        return await task.value
    }

    /// 覚えた値を捨てて、次回あらためて解決する。
    func invalidate() {
        environmentTask = nil
        codexPathTask = nil
    }
}
