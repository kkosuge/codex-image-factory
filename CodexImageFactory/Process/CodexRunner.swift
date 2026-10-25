import Foundation

/// サブプロセスの出力先。
enum CodexStream: String, Sendable, Codable {
    case stdout
    case stderr
}

/// サブプロセス 1 回分の起動内容。
struct CodexInvocation: Sendable, Equatable {
    var executableURL: URL
    var arguments: [String]
    var workingDirectory: URL
    /// 子プロセスに渡す環境変数（全体）。HOME を必ず含める。
    var environment: [String: String]
    /// 秒。超えたら中止と同じ手順（SIGINT → 3 秒後 SIGKILL）で止める。
    var timeout: TimeInterval
}

/// サブプロセスの終わり方。
struct ProcessOutcome: Sendable, Equatable {
    /// 終了コード。シグナルで終わった場合はシグナル番号（`Process.terminationStatus` と同じ）。
    var exitCode: Int32
    /// シグナルで終わったか（`Process.terminationReason == .uncaughtSignal`）。
    var terminatedBySignal: Bool
    /// 呼び出し側の Task がキャンセルされて止めたか。
    var cancelled: Bool
    /// タイムアウトで止めたか。
    var timedOut: Bool

    init(exitCode: Int32, terminatedBySignal: Bool = false, cancelled: Bool = false, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.terminatedBySignal = terminatedBySignal
        self.cancelled = cancelled
        self.timedOut = timedOut
    }
}

enum CodexRunnerError: Error, Equatable, LocalizedError {
    /// 実行ファイルが見つからない・起動できない。
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message): String(localized: "codex を起動できませんでした: \(message)")
        }
    }
}

/// codex を起動する部品。テストではダミーに差し替える。
protocol CodexRunning: Sendable {
    /// プロセスを起動し、終了まで待つ。
    ///
    /// - stdout / stderr は届いた順に 1 行ずつ（末尾の改行を除いて）`onLine` に渡す。最後の改行なしの行も渡す。
    /// - stdin は `/dev/null`（codex は stdin がパイプだと読みに行くため）。
    /// - 呼び出し側の Task がキャンセルされたら SIGINT を送り、3 秒たっても終わらなければ SIGKILL。
    ///   戻り値は `cancelled == true`。
    /// - `invocation.timeout` を超えたら同じ手順で止め、`timedOut == true`。
    /// - 起動できなかったときだけ throw する（`CodexRunnerError.launchFailed`）。
    func run(
        _ invocation: CodexInvocation,
        onLine: @escaping @Sendable (CodexStream, String) -> Void
    ) async throws -> ProcessOutcome
}
