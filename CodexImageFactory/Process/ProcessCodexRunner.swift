import Darwin
import Foundation

/// `Process` で codex を起動する本番用の `CodexRunning`。
///
/// - stdout / stderr は別々のパイプで読み、バイト単位で改行を探して 1 行ずつ `onLine` に渡す
///   （行末の `\r` は落とす。UTF-8 として読み、壊れたバイトは置換文字）。最後の改行なしの行も渡す。
/// - 両方のパイプが EOF になり、プロセスが終了するまで戻らない。孫プロセスがパイプを握ったまま残った場合だけ、
///   終了から `drainTimeout` 秒（既定 3 秒）で読むのをやめて戻る。
/// - 中止・タイムアウト: SIGINT → `killGracePeriod` 秒たっても終わらなければ SIGKILL（codex の子孫プロセスも）。
///   止めたあとに残った子孫（同じプロセスグループ・控えておいた子孫）も SIGKILL する。
/// - 呼ぶ前から Task がキャンセルされていたら起動せず、`ProcessOutcome(exitCode: -1, cancelled: true)` を返す。
/// - 同時に何本走らせてもよい（状態は 1 回の実行ごとに持つ）。
struct ProcessCodexRunner: CodexRunning {
    /// SIGINT を送ってから SIGKILL するまでの猶予（秒）。要件は 3 秒。
    var killGracePeriod: TimeInterval = 3
    /// 終了後にパイプの EOF を待つ上限（秒）。孫プロセスがパイプを握ったまま残ったときだけ効く。
    var drainTimeout: TimeInterval = 3

    init(killGracePeriod: TimeInterval = 3) {
        self.killGracePeriod = killGracePeriod
    }

    func run(
        _ invocation: CodexInvocation,
        onLine: @escaping @Sendable (CodexStream, String) -> Void
    ) async throws -> ProcessOutcome {
        // 起動前にキャンセル済みなら起動しない（exitCode は -1）。
        if Task.isCancelled {
            return ProcessOutcome(exitCode: ProcessSupportResult.notLaunchedExitCode, cancelled: true)
        }
        let stdoutSink = ProcessSupportLineSink(stream: .stdout, onLine: onLine)
        let stderrSink = ProcessSupportLineSink(stream: .stderr, onLine: onLine)
        let spec = ProcessSupportSpec(
            executableURL: invocation.executableURL,
            arguments: invocation.arguments,
            workingDirectory: invocation.workingDirectory,
            environment: invocation.environment,
            timeout: invocation.timeout,
            stopSignal: SIGINT,
            killGracePeriod: killGracePeriod,
            stderrMode: .separate,
            drainTimeout: drainTimeout
        )
        let result = try await ProcessSupportSession.run(
            spec,
            onData: { stream, data in
                switch stream {
                case .stdout: stdoutSink.append(data)
                case .stderr: stderrSink.append(data)
                }
            },
            onEnd: { stream in
                switch stream {
                case .stdout: stdoutSink.finish()
                case .stderr: stderrSink.finish()
                }
            }
        )
        return ProcessOutcome(
            exitCode: result.exitCode,
            terminatedBySignal: result.terminatedBySignal,
            cancelled: result.cancelled,
            timedOut: result.timedOut
        )
    }
}
