import Darwin
import Foundation
import Synchronization

/// stderr の扱い。
enum ProcessSupportStderrMode: Sendable, Equatable {
    /// stdout と別のパイプで読む。
    case separate
    /// stdout と同じパイプにまとめる（.stdout として届く）。
    case mergeIntoStdout
    /// 捨てる（/dev/null）。
    case discard
}

/// 子プロセス 1 回分の起動設定。ProcessCodexRunner と CodexEnvironment.runCapture で共通。
struct ProcessSupportSpec: Sendable {
    var executableURL: URL
    var arguments: [String]
    /// nil なら親と同じ。
    var workingDirectory: URL?
    /// nil なら親の環境変数をそのまま渡す。
    var environment: [String: String]?
    /// 秒。nil・0 以下・無限大ならタイムアウトなし。
    var timeout: TimeInterval?
    /// 止めるときに最初に送るシグナル。
    var stopSignal: Int32 = SIGINT
    /// stopSignal から SIGKILL までの猶予（秒）。
    var killGracePeriod: TimeInterval = 3
    var stderrMode: ProcessSupportStderrMode = .separate
    /// プロセス終了後にパイプの EOF を待つ上限（秒）。孫プロセスがパイプを握ったまま残ったときの保険。
    var drainTimeout: TimeInterval = 3
}

/// 子プロセスの終わり方。
struct ProcessSupportResult: Sendable, Equatable {
    /// 起動しなかったときの終了コード。
    static let notLaunchedExitCode: Int32 = -1

    var exitCode: Int32
    var terminatedBySignal: Bool
    var cancelled: Bool
    var timedOut: Bool
    /// 実際に起動したか（起動前にキャンセルされたら false）。
    var launched: Bool

    static let cancelledBeforeLaunch = ProcessSupportResult(
        exitCode: notLaunchedExitCode,
        terminatedBySignal: false,
        cancelled: true,
        timedOut: false,
        launched: false
    )
}

/// 子プロセス 1 回分の起動から終了までを受け持つ。
///
/// - 状態はすべて `state`（Mutex）で守る。終了通知・パイプ・タイマーのコールバックはどのスレッドから来てもよい。
/// - 終わる条件は「プロセスが終了した」かつ「読んでいるパイプがすべて EOF（または drainTimeout 経過）」。
///   終了通知が最後の出力より先に届いても、出力を取りこぼさない。
/// - 協調スレッドプールはブロックしない（待つのは terminationHandler・DispatchSource・continuation）。
final class ProcessSupportSession: Sendable {
    private enum StopReason {
        case cancel
        case timeout
    }

    private struct State {
        var continuation: CheckedContinuation<ProcessSupportResult, any Error>?
        var finished = false
        var cancelRequested = false
        var timedOut = false
        var launched = false
        var process: Process?
        var pid: pid_t = 0
        var isGroupLeader = false
        var stopping = false
        var terminated = false
        var postTerminationDone = false
        var exitCode: Int32 = ProcessSupportResult.notLaunchedExitCode
        var terminatedBySignal = false
        var openStreams: Set<CodexStream> = []
        /// 止める前に控えた子孫（親が先に終わると辿れなくなるため）。
        var descendants: [ProcessSupportProcessTree.Entry] = []
        var readers: [ProcessSupportPipeReader] = []
        var timers: [any DispatchSourceTimer] = []
    }

    /// タイマーに渡す秒数の上限（30 日）。
    private static let maxDelay: TimeInterval = 30 * 24 * 3600
    /// タイマーと停止処理を走らせるキュー。
    private static let workQueue = DispatchQueue.global(qos: .userInitiated)

    private let spec: ProcessSupportSpec
    private let onData: @Sendable (CodexStream, Data) -> Void
    private let onEnd: @Sendable (CodexStream) -> Void
    private let state = Mutex(State())

    private init(
        spec: ProcessSupportSpec,
        onData: @escaping @Sendable (CodexStream, Data) -> Void,
        onEnd: @escaping @Sendable (CodexStream) -> Void
    ) {
        self.spec = spec
        self.onData = onData
        self.onEnd = onEnd
    }

    /// 起動して終了まで待つ。
    ///
    /// - `onData` / `onEnd` はストリームごとに順番に呼ばれる。`onEnd` は読んだストリームすべてについて、戻る前に必ず呼ばれる。
    /// - Task がキャンセルされたら stopSignal → killGracePeriod 後に SIGKILL（子孫も）。
    /// - 起動できなかったときだけ `CodexRunnerError.launchFailed` を投げる。
    static func run(
        _ spec: ProcessSupportSpec,
        onData: @escaping @Sendable (CodexStream, Data) -> Void,
        onEnd: @escaping @Sendable (CodexStream) -> Void
    ) async throws -> ProcessSupportResult {
        let session = ProcessSupportSession(spec: spec, onData: onData, onEnd: onEnd)
        return try await withTaskCancellationHandler {
            try await session.start()
        } onCancel: {
            session.requestStop(.cancel)
        }
    }

    // MARK: - 起動

    private func start() async throws -> ProcessSupportResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessSupportResult, any Error>) in
            let alreadyCancelled = state.withLock { s -> Bool in
                if s.cancelRequested {
                    s.finished = true
                    return true
                }
                s.continuation = continuation
                return false
            }
            if alreadyCancelled {
                continuation.resume(returning: .cancelledBeforeLaunch)
                return
            }
            launch()
        }
    }

    private func launch() {
        if let message = preflightError() {
            failLaunch(message)
            return
        }

        let process = Process()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments
        if let dir = spec.workingDirectory {
            process.currentDirectoryURL = dir
        }
        if let environment = spec.environment {
            process.environment = environment
        }
        // codex は stdin がパイプやファイルだと読みに行くので、必ず /dev/null にする。
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        var stderrPipe: Pipe?
        switch spec.stderrMode {
        case .separate:
            let pipe = Pipe()
            stderrPipe = pipe
            process.standardError = pipe
        case .mergeIntoStdout:
            process.standardError = stdoutPipe
        case .discard:
            process.standardError = FileHandle.nullDevice
        }
        process.terminationHandler = { [self] finished in
            handleTermination(status: finished.terminationStatus, bySignal: finished.terminationReason == .uncaughtSignal)
        }

        // 起動直前にもう一度キャンセルを確かめる。
        let streams: Set<CodexStream> = stderrPipe == nil ? [.stdout] : [.stdout, .stderr]
        let proceed = state.withLock { s -> Bool in
            guard !s.cancelRequested else { return false }
            s.openStreams = streams
            return true
        }
        guard proceed else {
            finishWithoutLaunch()
            return
        }

        do {
            try process.run()
        } catch {
            failLaunch(error.localizedDescription)
            return
        }

        // Foundation の Process は子を新しいプロセスグループのリーダーにする（確認済み）。念のため確かめてから killpg に使う。
        let pid = process.processIdentifier
        let isGroupLeader = pid > 1 && getpgid(pid) == pid
        // 書き口は Process が親側で閉じている（触ると例外になるので触らない）。
        var readers = [makeReader(.stdout, handle: stdoutPipe.fileHandleForReading)]
        if let stderrPipe {
            readers.append(makeReader(.stderr, handle: stderrPipe.fileHandleForReading))
        }

        let (stopNow, runPostTermination) = state.withLock { s -> (Bool, Bool) in
            s.launched = true
            s.process = process
            s.pid = pid
            s.isGroupLeader = isGroupLeader
            s.readers = readers
            let post = s.terminated && !s.postTerminationDone
            if post {
                s.postTerminationDone = true
            }
            let stop = !s.terminated && !s.stopping && (s.cancelRequested || s.timedOut)
            if stop {
                s.stopping = true
            }
            return (stop, post)
        }

        for reader in readers {
            reader.start()
        }
        if let timeout = Self.effectiveTimeout(spec.timeout) {
            schedule(after: timeout) { [self] in requestStop(.timeout) }
        }
        if stopNow {
            beginStop(pid: pid)
        }
        if runPostTermination {
            afterTermination()
        }
    }

    private func makeReader(_ stream: CodexStream, handle: FileHandle) -> ProcessSupportPipeReader {
        let onData = self.onData
        return ProcessSupportPipeReader(
            stream: stream,
            handle: handle,
            onData: { data in onData(stream, data) },
            onEnd: { [self] in
                onEnd(stream)
                streamEnded(stream)
            }
        )
    }

    private func preflightError() -> String? {
        let fm = FileManager.default
        let path = spec.executableURL.path
        var isDirectory: ObjCBool = false
        guard !path.isEmpty, fm.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return "実行ファイルが見つかりません: \(path)"
        }
        if isDirectory.boolValue {
            return "フォルダは実行できません: \(path)"
        }
        guard fm.isExecutableFile(atPath: path) else {
            return "実行権限がありません: \(path)"
        }
        if let dir = spec.workingDirectory {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                return "作業フォルダがありません: \(dir.path)"
            }
        }
        return nil
    }

    // MARK: - 中止・タイムアウト

    private func requestStop(_ reason: StopReason) {
        enum Action {
            case none
            case begin(pid_t)
            case cleanup
        }
        let action = state.withLock { s -> Action in
            switch reason {
            case .cancel:
                s.cancelRequested = true
            case .timeout:
                // 先に終わっていたらタイムアウト扱いにしない。
                guard !s.terminated, !s.finished else { return .none }
                s.timedOut = true
            }
            guard s.launched, !s.finished else { return .none }
            if s.terminated {
                // 終了済みでパイプの EOF 待ち。パイプを握った子孫が残っていれば止める。
                return s.postTerminationDone ? .cleanup : .none
            }
            guard !s.stopping else { return .none }
            s.stopping = true
            return .begin(s.pid)
        }
        // onCancel は呼び出し側のスレッド（メインスレッドのこともある）で走るので、プロセス表の読み取りとシグナルは別キューで行う。
        switch action {
        case .none:
            break
        case .begin(let pid):
            Self.workQueue.async { [self] in beginStop(pid: pid) }
        case .cleanup:
            Self.workQueue.async { [self] in killLeftovers() }
        }
    }

    /// stopSignal を送り、猶予のあとで SIGKILL する。
    private func beginStop(pid: pid_t) {
        // 親が先に終わると子は launchd の子になって辿れなくなるので、シグナルの前に子孫を控える。
        let found = ProcessSupportProcessTree.descendants(of: pid)
        let alreadyTerminated = state.withLock { s -> Bool in
            s.descendants.append(contentsOf: found)
            return s.terminated
        }
        if alreadyTerminated {
            killLeftovers()
            return
        }
        ProcessSupportProcessTree.send(spec.stopSignal, to: pid)
        schedule(after: spec.killGracePeriod) { [self] in escalate() }
    }

    /// 猶予を過ぎても終わらないので SIGKILL する（本体・プロセスグループ・子孫）。
    private func escalate() {
        let target = state.withLock { s -> (pid: pid_t, groupLeader: Bool)? in
            guard s.launched, !s.terminated, !s.finished else { return nil }
            return (s.pid, s.isGroupLeader)
        }
        guard let target else { return }
        let fresh = ProcessSupportProcessTree.descendants(of: target.pid)
        let known = state.withLock { s -> [ProcessSupportProcessTree.Entry] in
            s.descendants.append(contentsOf: fresh)
            return s.descendants
        }
        ProcessSupportProcessTree.send(SIGKILL, to: target.pid)
        if target.groupLeader {
            ProcessSupportProcessTree.sendToGroup(SIGKILL, groupId: target.pid)
        }
        ProcessSupportProcessTree.signalIfStillRunning(known, signal: SIGKILL)
    }

    /// 中止・タイムアウトで本体が終わったあと、残った子孫を SIGKILL する。
    /// 本体の PID には送らない（終了後は使い回されうるため）。グループ ID はメンバーが残っている間は使い回されない。
    private func killLeftovers() {
        let target = state.withLock { s in
            (pid: s.pid, groupLeader: s.isGroupLeader, known: s.descendants)
        }
        if target.groupLeader {
            ProcessSupportProcessTree.sendToGroup(SIGKILL, groupId: target.pid)
        }
        ProcessSupportProcessTree.signalIfStillRunning(target.known, signal: SIGKILL)
    }

    // MARK: - 終了

    private func handleTermination(status: Int32, bySignal: Bool) {
        let runPostTermination = state.withLock { s -> Bool in
            s.terminated = true
            s.exitCode = status
            s.terminatedBySignal = bySignal
            guard s.launched, !s.postTerminationDone else { return false }
            s.postTerminationDone = true
            return true
        }
        if runPostTermination {
            afterTermination()
        }
    }

    /// 終了通知を受け、起動処理も済んだあとに 1 回だけ呼ぶ。
    private func afterTermination() {
        let stopRequested = state.withLock { $0.cancelRequested || $0.timedOut }
        if stopRequested {
            killLeftovers()
        }
        schedule(after: spec.drainTimeout) { [self] in forceCloseReaders() }
        tryFinish()
    }

    private func forceCloseReaders() {
        let readers = state.withLock { $0.readers }
        for reader in readers {
            reader.forceClose()
        }
    }

    private func streamEnded(_ stream: CodexStream) {
        state.withLock { s in
            _ = s.openStreams.remove(stream)
        }
        tryFinish()
    }

    private func tryFinish() {
        let done = state.withLock { s -> (CheckedContinuation<ProcessSupportResult, any Error>, ProcessSupportResult, [any DispatchSourceTimer])? in
            guard !s.finished, s.launched, s.terminated, s.openStreams.isEmpty, let continuation = s.continuation else {
                return nil
            }
            s.finished = true
            s.continuation = nil
            let result = ProcessSupportResult(
                exitCode: s.exitCode,
                terminatedBySignal: s.terminatedBySignal,
                cancelled: s.cancelRequested,
                timedOut: s.timedOut,
                launched: true
            )
            let timers = s.timers
            s.timers = []
            s.readers = []
            s.process = nil
            return (continuation, result, timers)
        }
        guard let (continuation, result, timers) = done else { return }
        for timer in timers {
            timer.cancel()
        }
        continuation.resume(returning: result)
    }

    private func finishWithoutLaunch() {
        if let continuation = takeContinuationForEarlyExit() {
            continuation.resume(returning: .cancelledBeforeLaunch)
        }
    }

    private func failLaunch(_ message: String) {
        if let continuation = takeContinuationForEarlyExit() {
            continuation.resume(throwing: CodexRunnerError.launchFailed(message))
        }
    }

    private func takeContinuationForEarlyExit() -> CheckedContinuation<ProcessSupportResult, any Error>? {
        state.withLock { s in
            guard !s.finished else { return nil }
            s.finished = true
            let continuation = s.continuation
            s.continuation = nil
            return continuation
        }
    }

    // MARK: - タイマー

    private func schedule(after seconds: TimeInterval, _ handler: @escaping @Sendable () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: Self.workQueue)
        timer.schedule(deadline: .now() + Self.clampedDelay(seconds))
        timer.setEventHandler(handler: handler)
        let accepted = state.withLock { s -> Bool in
            guard !s.finished else { return false }
            s.timers.append(timer)
            return true
        }
        if !accepted {
            timer.cancel()
        }
        // 一度も resume しないまま解放するとクラッシュするので、キャンセルした場合も resume する。
        timer.resume()
    }

    private static func effectiveTimeout(_ timeout: TimeInterval?) -> TimeInterval? {
        guard let timeout, timeout.isFinite, timeout > 0 else { return nil }
        return min(timeout, maxDelay)
    }

    private static func clampedDelay(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return seconds > 0 ? maxDelay : 0 }
        return min(max(0, seconds), maxDelay)
    }
}

/// パイプの読み口を DispatchSource で読む。
///
/// イベントはパイプごとの直列キューで届くので、届いた順に `onData` を呼ぶ。EOF（または forceClose）で
/// 読み口を閉じ、最後に `onEnd` を 1 回だけ呼ぶ。
final class ProcessSupportPipeReader: Sendable {
    private static let chunkSize = 64 * 1024

    private let source: any DispatchSourceRead

    init(
        stream: CodexStream,
        handle: FileHandle,
        onData: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable () -> Void
    ) {
        let fd = handle.fileDescriptor
        // 読み口は親だけが持つので、非ブロッキングにしても子には影響しない。
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        let queue = DispatchQueue(label: "ProcessSupport.pipe.\(stream.rawValue)", qos: .userInitiated)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        // ハンドラは source 自身を参照するが、キャンセル後に libdispatch が解放するので循環は残らない。
        source.setEventHandler {
            Self.drain(fd: fd, source: source, onData: onData)
        }
        source.setCancelHandler {
            try? handle.close()
            onEnd()
        }
        self.source = source
    }

    /// 読み始める。1 回だけ呼ぶ。
    func start() {
        source.resume()
    }

    /// EOF を待たずに閉じる（読みかけの分は届けてから onEnd）。
    func forceClose() {
        source.cancel()
    }

    private static func drain(fd: Int32, source: any DispatchSourceRead, onData: (Data) -> Void) {
        withUnsafeTemporaryAllocation(byteCount: chunkSize, alignment: 16) { buffer in
            guard let base = buffer.baseAddress else { return }
            while true {
                let n = read(fd, base, chunkSize)
                if n > 0 {
                    onData(Data(bytes: base, count: n))
                    if n < chunkSize {
                        // 残りがあれば次のイベントでまた呼ばれる。
                        return
                    }
                    continue
                }
                if n == 0 {
                    source.cancel()
                    return
                }
                let error = errno
                if error == EINTR {
                    continue
                }
                if error == EAGAIN || error == EWOULDBLOCK {
                    return
                }
                // 読めないエラーは EOF とみなす。
                source.cancel()
                return
            }
        }
    }
}

/// 短いコマンドを実行して出力をまとめて受け取る（CodexEnvironment 用）。
enum ProcessSupportCapture {
    struct Output: Sendable, Equatable {
        var exitCode: Int32
        var terminatedBySignal: Bool
        var timedOut: Bool
        var cancelled: Bool
        var data: Data

        /// UTF-8 として読んだ出力（壊れたバイトは置換文字）。
        var text: String {
            String(decoding: data, as: UTF8.self)
        }
    }

    /// stdin は /dev/null。タイムアウトしたら SIGTERM → 1 秒後に SIGKILL（子孫も）。
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: URL? = nil,
        timeout: TimeInterval,
        includeStderr: Bool
    ) async -> Result<Output, CodexRunnerError> {
        let box = ProcessSupportDataBox()
        let spec = ProcessSupportSpec(
            executableURL: URL(fileURLWithPath: PathUtil.expandTilde(executable)),
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeout: timeout,
            stopSignal: SIGTERM,
            killGracePeriod: 1,
            stderrMode: includeStderr ? .mergeIntoStdout : .discard,
            drainTimeout: 1
        )
        do {
            let result = try await ProcessSupportSession.run(spec, onData: { _, data in box.append(data) }, onEnd: { _ in })
            return .success(Output(
                exitCode: result.exitCode,
                terminatedBySignal: result.terminatedBySignal,
                timedOut: result.timedOut,
                cancelled: result.cancelled,
                data: box.data
            ))
        } catch let error as CodexRunnerError {
            return .failure(error)
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }
    }
}
