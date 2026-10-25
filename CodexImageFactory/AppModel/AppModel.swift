import Foundation
import Observation
import Synchronization

/// codex の場所とログイン状態の確認結果。
enum CodexCheckState: Equatable, Sendable {
    case idle
    case checking
    /// 自動検出でも見つからない。
    case missing
    /// 設定で指定したパスが無い・実行できない。
    case invalidPath(String)
    /// codex を起動できなかった、または `codex login status` が時間内に終わらなかった（ログイン状態は分からない）。
    case launchFailed(path: String, output: String)
    case loggedIn(path: String, output: String)
    /// codex は動いたが、ログインしていないと答えた（終了コードが 0 以外、または「Not logged in」）。
    case notLoggedIn(path: String, output: String)

    /// 設定欄の「ログイン状態」に出す文言。
    var label: String {
        switch self {
        case .idle:
            String(localized: "未確認", comment: "codex のログイン状態: まだ確認していない")
        case .checking:
            String(localized: "確認中…", comment: "codex のログイン状態: 確認している途中")
        case .missing:
            String(localized: "codex が見つかりません")
        case .invalidPath:
            String(localized: "指定したパスの codex を実行できません")
        case .launchFailed(_, let output):
            output.isEmpty
                ? String(localized: "codex を起動できません")
                : String(localized: "codex を起動できません（\(UIDisplayFormat.firstLine(output))）")
        case .loggedIn(_, let output):
            output.isEmpty
                ? String(localized: "ログイン済み")
                : String(localized: "ログイン済み（\(UIDisplayFormat.firstLine(output))）", comment: "codex のログイン状態。引数は codex の出力の 1 行目")
        case .notLoggedIn(_, let output):
            output.isEmpty
                ? String(localized: "未ログイン")
                : String(localized: "未ログイン（\(UIDisplayFormat.firstLine(output))）", comment: "codex のログイン状態。引数は codex の出力の 1 行目")
        }
    }
}

/// レート制限のバナーの中身。
struct RateLimitNotice: Equatable, Sendable {
    var jobID: UUID
    var slug: String
    var message: String
}

/// 閉じられるお知らせ（エラーなど）。
struct AppNotice: Identifiable, Equatable, Sendable {
    var id = UUID()
    var text: String
}

/// deinit から Task を止めるための入れ物。中身は Mutex で守るので Sendable。
final class AppModelTaskBag: Sendable {
    private let tasks = Mutex<[Task<Void, Never>]>([])

    func add(_ task: Task<Void, Never>) {
        tasks.withLock { $0.append(task) }
    }

    func cancelAll() {
        let all = tasks.withLock { list in
            defer { list.removeAll() }
            return list
        }
        all.forEach { $0.cancel() }
    }
}

/// 画面の状態をまとめて持つ。UI はこれだけを見る。
@MainActor
@Observable
final class AppModel {
    static let drainedNotificationTitle = String(localized: "キューのジョブがすべて終わりました")
    /// 終わったジョブのライブログを何件まで覚えておくか。
    static let retainedLiveLogCount = 30
    /// 履歴を一度に何件まで並べるか（「さらに表示」で増やす）。
    static let historyPageSize = 300
    /// 固定の指示文の入力が止まってから反映するまでの時間。
    static let templateCommitDelay: Duration = .seconds(1)
    /// 「再開」を押したが、codex の確認などがまだ終わっていないときの文言。
    static let resumeWaitingText = String(localized: "codex の場所を確認しています…確認が終わりしだいキューを再開します。")
    /// 設定の入力欄の下に出す説明。
    static let settingsCommitHint = String(localized: "Return を押すか、ほかの欄へ移るか、「設定の変更を反映」を押すと反映します。")

    // MARK: - 入力

    var draft = JobDraft()
    var referencePathInput = ""
    private(set) var referenceError: String?
    /// 入力欄の下に出す結果の文言（「1 件をキューに追加しました」など）。
    private(set) var inputMessage: String?
    /// 編集中の待機中ジョブ。
    private(set) var editingJobID: UUID?
    @ObservationIgnored private var editingOriginal: JobRecord?
    /// 編集を始める前の入力内容。「編集をやめる」「変更を保存」で戻す。
    /// 保存できなかったときは編集した内容を入力欄に残し、こちらは「編集前の入力に戻す」で戻せるように取っておく。
    private(set) var stashedDraft: JobDraft?

    // MARK: - 設定

    private var storedSettings: AppSettings
    /// 設定。書き換えると保存し、キューへ渡す。
    var settings: AppSettings {
        get { storedSettings }
        set {
            let old = storedSettings
            storedSettings = newValue
            settingsDidChange(from: old)
        }
    }

    private var storedTimeoutText: String
    /// タイムアウト（分）の入力欄。正しい値のときだけ settings.timeoutSeconds に反映する。
    var timeoutMinutesText: String {
        get { storedTimeoutText }
        set {
            storedTimeoutText = newValue
            applyTimeoutText()
        }
    }
    private(set) var timeoutError: String?
    var isSettingsVisible = false
    /// 設定を画面に出すように頼まれた回数。増えたら設定の位置までスクロールする。
    private(set) var settingsScrollRequest = 0
    /// ログインシェルで見つけた codex のパス。
    private(set) var detectedCodexPath: String?
    private(set) var codexCheck: CodexCheckState = .idle

    // MARK: - 設定の入力欄（下書き）

    // 出力ディレクトリ・codex のパス・モデルは入力途中の値をキューへ渡さないよう、下書きに書いてから
    // Return かほかの欄へ移ったとき（commit…Draft）に確かめて反映する。だめな値は理由を出して反映しない。
    var outputDirectoryDraft: String
    var codexPathDraft: String
    var modelDraft: String
    private(set) var outputDirectoryError: String?
    private(set) var codexPathError: String?
    private(set) var modelError: String?
    private var storedTemplateDraft: String
    /// 固定の指示文の入力欄。入力が止まって templateCommitDelay たつか、ほかの欄へ移ったときに反映する。
    var instructionTemplateDraft: String {
        get { storedTemplateDraft }
        set {
            guard storedTemplateDraft != newValue else { return }
            storedTemplateDraft = newValue
            scheduleTemplateCommit()
        }
    }

    // MARK: - キュー

    private(set) var queued: [JobRecord] = []
    private(set) var running: [JobRecord] = []
    private(set) var isPaused = false
    /// 「再開」を押して、復元・codex のパス解決・設定の反映が終わるのを待っている。
    private(set) var isResumePending = false
    /// キュー・履歴の操作の結果の文言。
    private(set) var queueMessage: String?
    private(set) var liveLogs: [UUID: LiveJobLog] = [:]

    // MARK: - 履歴

    /// 新しい順。
    private(set) var history: [JobRecord] = []
    private(set) var isLoadingHistory = false
    /// 履歴の欄に並べる件数。行はすべてアクセシビリティツリーに出すので、多すぎるときは区切る。
    private(set) var historyDisplayLimit = AppModel.historyPageSize

    // MARK: - 詳細

    private(set) var selectedJobID: UUID?
    private(set) var detailMessage: String?
    var logDisplayMode: LogDisplayMode = .formatted

    // MARK: - バナー

    private(set) var rateLimitNotice: RateLimitNotice?
    private(set) var restoredNotice: String?
    private(set) var notices: [AppNotice] = []

    // MARK: - 内部

    let queue: any JobQueueing
    private let deps: AppDependencies
    private let taskBag = AppModelTaskBag()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var isShuttingDown = false
    /// 起動時の復元が終わるまで、追加を待たせる。
    @ObservationIgnored private var startupGate: Task<Void, Never>?
    /// codex のパスの解決。終わるまで追加を待たせる（空のパスで起動しないように）。
    @ObservationIgnored private var pathResolution: Task<Void, Never>?
    @ObservationIgnored private var settingsPush: Task<Void, Never>?
    @ObservationIgnored private var lastPushedSettings: AppSettings?
    @ObservationIgnored private var codexCheckTask: Task<Void, Never>?
    @ObservationIgnored private var codexRecheckDebounce: Task<Void, Never>?
    @ObservationIgnored private var historyLoadTask: Task<Void, Never>?
    @ObservationIgnored private var historyReloadDebounce: Task<Void, Never>?
    /// 履歴の索引（history.json）の読み書きを 1 つずつ順に行うための鎖。
    @ObservationIgnored private var historyWork: Task<Void, Never>?
    @ObservationIgnored private var sessionFinishedIDs: Set<UUID> = []
    @ObservationIgnored private var finishedLiveLogOrder: [UUID] = []
    @ObservationIgnored private var drainCounts = DrainCounts()
    /// キューへ渡すのを待っている追加（追加した順）。
    @ObservationIgnored private var pendingAdds: [PendingAdd] = []
    /// 追加を 1 つずつ順に渡すための鎖（同じ Task を複数で待つと再開の順が入れ替わるため）。
    @ObservationIgnored private var addChain: Task<Void, Never>?
    /// 「再開」の頼み。待っている間に一時停止や別の再開が来たら古い頼みは捨てる。
    @ObservationIgnored private var resumeRequest = 0
    /// 中止を頼んだジョブ。`.finished` が届いたら「中止しています…」を書き換える。
    @ObservationIgnored private var cancellingJobIDs: Set<UUID> = []
    @ObservationIgnored private var templateCommitDebounce: Task<Void, Never>?

    private struct DrainCounts {
        var done = 0
        var failed = 0
        var cancelled = 0
        var total: Int { done + failed + cancelled }
    }

    private struct PendingAdd {
        var id: UUID
        var jobs: [JobRecord]
    }

    init(dependencies: AppDependencies) {
        deps = dependencies
        let loaded = dependencies.settingsStore.load()
        storedSettings = loaded
        storedTimeoutText = Self.minutesText(fromSeconds: loaded.timeoutSeconds)
        outputDirectoryDraft = loaded.outputDirectory
        codexPathDraft = loaded.codexPath
        modelDraft = loaded.model
        storedTemplateDraft = loaded.instructionTemplate
        var initial = loaded
        initial.codexPath = Self.expandedPath(loaded.codexPath, home: dependencies.homeDirectory)
        queue = dependencies.makeQueue(initial)
        lastPushedSettings = initial
        startEventLoop()
    }

    deinit {
        taskBag.cancelAll()
    }

    // MARK: - 起動・終了

    /// ウィンドウが出たときに 1 回だけ呼ぶ。履歴の読み込み、待機中ジョブの復元、codex の確認、通知の許可。
    func start() {
        guard !started else { return }
        started = true

        reloadHistory()

        // 追加より先に復元したいので、小さな queue.json はその場で読む。
        let saved = deps.loadSavedQueue()
        let q = queue
        startupGate = Task { [weak self] in
            guard !saved.isEmpty else { return }
            await q.restore(saved)
            self?.restoredNotice = String(localized: "前回の待機中ジョブを \(saved.count) 件復元しました（一時停止中）。「再開」で実行します。")
        }

        recheckCodex(invalidate: false)

        let notifier = deps.notifier
        Task { await notifier.requestAuthorization() }
    }

    /// 終了前に呼ぶ。実行中のジョブを止め、待機中一覧を保存する（最大 5 秒）。
    /// codex の確認などを待っている追加は、待たずにキューへ渡して保存させる（入力欄はもう空にしているため）。
    func shutdown() async {
        isShuttingDown = true
        let pending = pendingAdds.flatMap(\.jobs)
        pendingAdds.removeAll()
        if !pending.isEmpty {
            // 復元したジョブより後ろに並べる。一時停止にしてから渡すので、空のパスなどで起動することはない。
            await startupGate?.value
            await queue.pause()
            await queue.enqueue(pending)
        }
        await queue.shutdown(timeout: 5)
    }

    /// 終了時にキューの後始末を待つ必要があるか。
    var needsGracefulShutdown: Bool {
        !running.isEmpty || (!queued.isEmpty && !isPaused) || !pendingAdds.isEmpty
    }

    /// アプリが終わる直前に呼ぶ。まだ反映していない設定の入力欄を、正しい値なら反映して保存する。
    func flushPendingSettingsEdits() {
        commitSettingDrafts()
    }

    private func startEventLoop() {
        let stream = queue.events
        let task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
        taskBag.add(task)
    }

    // MARK: - キューからの通知

    func handle(_ event: QueueEvent) {
        switch event {
        case .snapshot(let snapshot):
            apply(snapshot)
        case .line(let jobID, let stream, let text):
            liveLog(creatingFor: jobID).append(stream: stream, text: text)
        case .finished(let record):
            recordFinished(record)
        case .rateLimited(let jobID, let message):
            rateLimitNotice = RateLimitNotice(jobID: jobID, slug: slug(of: jobID) ?? "", message: message)
        case .drained:
            postDrainedNotification()
        }
    }

    private func apply(_ snapshot: QueueSnapshot) {
        if queued != snapshot.queued { queued = snapshot.queued }
        if running != snapshot.running { running = snapshot.running }
        if isPaused != snapshot.isPaused { isPaused = snapshot.isPaused }
        for job in snapshot.running where liveLogs[job.id] == nil {
            liveLogs[job.id] = LiveJobLog()
        }
    }

    private func liveLog(creatingFor id: UUID) -> LiveJobLog {
        if let log = liveLogs[id] {
            return log
        }
        let log = LiveJobLog()
        liveLogs[id] = log
        return log
    }

    private func recordFinished(_ record: JobRecord) {
        if running.contains(where: { $0.id == record.id }) {
            running.removeAll { $0.id == record.id }
        }
        var list = history
        list.removeAll { $0.id == record.id }
        list.insert(record, at: 0)
        history = list
        sessionFinishedIDs.insert(record.id)

        if cancellingJobIDs.remove(record.id) != nil {
            queueMessage = record.status == .cancelled
                ? String(localized: "「\(record.slug)」を中止しました")
                : String(localized: "「\(record.slug)」は中止する前に終わりました（\(record.status.label)）")
        }

        switch record.status {
        case .done: drainCounts.done += 1
        case .failed: drainCounts.failed += 1
        case .cancelled: drainCounts.cancelled += 1
        case .queued, .running: break
        }

        let register = deps.registerHistory
        scheduleHistoryWork { register(record) }

        // ライブログは詳細ペイン用にしばらく残す。古いものから捨てる。
        finishedLiveLogOrder.removeAll { $0 == record.id }
        finishedLiveLogOrder.append(record.id)
        while finishedLiveLogOrder.count > Self.retainedLiveLogCount {
            let old = finishedLiveLogOrder.removeFirst()
            liveLogs[old] = nil
        }
    }

    private func postDrainedNotification() {
        let counts = drainCounts
        drainCounts = DrainCounts()
        guard !isShuttingDown, counts.total > 0 else { return }
        let body = counts.cancelled > 0
            ? String(localized: "完了 \(counts.done) 件 · 失敗 \(counts.failed) 件 · 中止 \(counts.cancelled) 件")
            : String(localized: "完了 \(counts.done) 件 · 失敗 \(counts.failed) 件")
        let notifier = deps.notifier
        Task { await notifier.post(title: Self.drainedNotificationTitle, body: body) }
    }

    private func slug(of id: UUID) -> String? {
        (running.first { $0.id == id } ?? queued.first { $0.id == id } ?? history.first { $0.id == id })?.slug
    }

    // MARK: - 入力: 追加

    /// 「生成（キューに追加）」。入力欄はすぐ空にする。
    func addSingle() async {
        guard !isEditing else { return }
        // 入力したのに反映していない設定（出力先など）があれば、先に反映してから追加する。
        if hasPendingSettingDrafts {
            commitSettingDrafts()
        }
        guard let job = JobFactory.single(
            from: draft,
            preset: settings.stylePreset,
            template: settings.normalized().instructionTemplate,
            now: deps.now()
        ) else { return }
        clearPromptAfterAdd()
        inputMessage = String(localized: "1 件をキューに追加しました（\(job.slug)）")
        await enqueue([job])
    }

    /// 「まとめて追加」。空行区切りのプロンプトを 1 件ずつ。
    func addBatch() async {
        guard !isEditing else { return }
        if hasPendingSettingDrafts {
            commitSettingDrafts()
        }
        let jobs = JobFactory.batch(
            from: draft,
            preset: settings.stylePreset,
            template: settings.normalized().instructionTemplate,
            now: deps.now()
        )
        guard !jobs.isEmpty else { return }
        clearPromptAfterAdd()
        inputMessage = String(localized: "\(jobs.count) 件をキューに追加しました")
        await enqueue(jobs)
    }

    private func clearPromptAfterAdd() {
        draft.prompt = ""
        draft.slug = ""
        referenceError = nil
    }

    /// 追加した順にキューへ渡す。前の追加が渡し終わってから、復元・codex のパス解決・設定の反映を待って渡す。
    private func enqueue(_ jobs: [JobRecord]) async {
        let ticket = UUID()
        pendingAdds.append(PendingAdd(id: ticket, jobs: jobs))
        let previous = addChain
        let link = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.waitUntilQueueReady()
            await self.deliverPendingAdd(ticket)
        }
        addChain = link
        await link.value
    }

    private func deliverPendingAdd(_ ticket: UUID) async {
        // 終了処理が先に渡していれば何もしない。
        guard let index = pendingAdds.firstIndex(where: { $0.id == ticket }) else { return }
        let add = pendingAdds.remove(at: index)
        await queue.enqueue(add.jobs)
    }

    /// 復元・codex のパス解決・設定の反映が終わるまで待つ。
    func waitUntilQueueReady() async {
        await startupGate?.value
        await pathResolution?.value
        await settingsPush?.value
    }

    // MARK: - 入力: 参照画像

    /// パスを検証して参照画像に足す。だめなら referenceError に理由を入れる。
    @discardableResult
    func addReferencePath(_ raw: String) -> Bool {
        switch ReferenceImageValidator.validate(raw, existing: draft.referenceImages, home: deps.homeDirectory) {
        case .success(let path):
            draft.referenceImages.append(path)
            referenceError = nil
            return true
        case .failure(let failure):
            referenceError = failure.message
            return false
        }
    }

    /// 「パスを追加」。
    func addReferenceFromInput() {
        if addReferencePath(referencePathInput) {
            referencePathInput = ""
        }
    }

    /// ドラッグ＆ドロップ・ファイル選択から。1 つでも足せたら true。
    @discardableResult
    func addReferenceURLs(_ urls: [URL]) -> Bool {
        var added = false
        var errors: [String] = []
        for url in urls {
            guard url.isFileURL else {
                errors.append(ReferenceImageValidator.Failure.notFound(url.absoluteString).message)
                continue
            }
            switch ReferenceImageValidator.validate(url.path, existing: draft.referenceImages, home: deps.homeDirectory) {
            case .success(let path):
                draft.referenceImages.append(path)
                added = true
            case .failure(let failure):
                if !errors.contains(failure.message) {
                    errors.append(failure.message)
                }
            }
        }
        referenceError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        return added
    }

    func removeReference(at index: Int) {
        guard draft.referenceImages.indices.contains(index) else { return }
        draft.referenceImages.remove(at: index)
        referenceError = nil
    }

    // MARK: - 入力: 待機中ジョブの編集

    var isEditing: Bool { editingJobID != nil }

    /// 編集中のジョブ（まだ待機中のときだけ）。
    var editingJob: JobRecord? {
        guard let id = editingJobID else { return nil }
        return queued.first { $0.id == id }
    }

    /// 「どのジョブを編集中か」の文言。
    var editingStatusText: String? {
        guard isEditing else { return nil }
        let slug = editingJob?.slug ?? editingOriginal?.slug ?? ""
        if editingJob == nil {
            return String(localized: "待機中ジョブ「\(slug)」を編集中ですが、このジョブは実行が始まったか削除されたため、変更を反映できません。「変更を保存」を押すと、編集した内容を入力欄に残したまま編集を終えます（「生成（キューに追加）」で新しいジョブとして追加できます）。「編集をやめる」を押すと、編集した内容を捨てて編集前の入力に戻します。")
        }
        return String(localized: "待機中ジョブ「\(slug)」を編集中です。「変更を保存」で反映します。")
    }

    /// 「変更を保存」を押せるか。ジョブが待機中でなくなっていても押せる（編集した内容を残して編集を終える）。
    var canSaveEdit: Bool {
        isEditing && draft.canSubmit
    }

    /// 「編集前の入力に戻す」を出すか（保存できずに編集を終えたあと）。
    var canRestoreStashedDraft: Bool {
        !isEditing && stashedDraft != nil
    }

    /// 編集を始めてから入力を変えたか。
    private var hasUnsavedEdits: Bool {
        guard isEditing, let original = editingOriginal else { return false }
        return JobFactory.draft(from: original) != draft
    }

    /// キューの「編集」。入力欄にジョブの内容を入れる。それまでの入力は取っておき、編集が終わったら戻す。
    func beginEditing(_ jobID: UUID) {
        guard let job = queued.first(where: { $0.id == jobID }) else { return }
        if isEditing {
            guard editingJobID != jobID else { return }
            // 別のジョブに切り替えると編集した内容が消えるので、保存かやめるのを先にしてもらう。
            if hasUnsavedEdits {
                let slug = editingJob?.slug ?? editingOriginal?.slug ?? ""
                inputMessage = String(localized: "「\(slug)」の編集中です。「変更を保存」か「編集をやめる」を押してから、ほかのジョブを編集してください。")
                return
            }
        } else if let stash = stashedDraft, !Self.isBlank(stash), !Self.isBlank(draft) {
            // 取っておいた入力といまの入力の両方があると、どちらかを捨てることになるので先に片付けてもらう。
            inputMessage = String(localized: "前に取っておいた入力が残っています。いまの入力を「生成（キューに追加）」で追加するか、「編集前の入力に戻す」で入れ替えて片付けてから、もう一度「編集」を押してください。")
            return
        } else if stashedDraft == nil || !Self.isBlank(draft) {
            // 前に保存できなかったときの「編集前の入力」は、いまの入力が空なら残しておく。
            stashedDraft = draft
        }
        editingJobID = job.id
        editingOriginal = job
        draft = JobFactory.draft(from: job)
        referenceError = nil
        inputMessage = nil
    }

    /// 「変更を保存」。ジョブがもう待機中でなければ、編集した内容を入力欄に残して編集を終える。
    func saveEdit() async {
        guard let id = editingJobID else { return }
        guard let base = queued.first(where: { $0.id == id }) ?? editingOriginal,
              let updated = JobFactory.apply(draft, to: base, template: settings.normalized().instructionTemplate) else {
            inputMessage = String(localized: "プロンプトが空なので保存できません。")
            return
        }
        var ok = false
        if editingJob != nil {
            ok = await queue.update(updated)
        }
        guard editingJobID == id else { return }
        if ok {
            finishEditing(restoreDraft: true)
            inputMessage = String(localized: "「\(updated.slug)」の変更を保存しました")
        } else {
            // 編集した内容は入力欄に残し、新しいジョブとして追加できるようにする。編集前の入力も捨てない。
            finishEditing(restoreDraft: false)
            inputMessage = String(localized: "「\(updated.slug)」はすでに実行が始まったか削除されたため、変更を保存できませんでした。編集した内容は入力欄に残してあるので、「生成（キューに追加）」で新しいジョブとして追加できます。")
                + (stashedDraft != nil ? String(localized: "編集前の入力は「編集前の入力に戻す」で戻せます。") : "")
        }
    }

    /// 「編集をやめる」。編集した内容を捨て、編集前の入力に戻す。
    func cancelEditing() {
        guard isEditing else { return }
        finishEditing(restoreDraft: true)
        inputMessage = String(localized: "編集をやめました")
    }

    /// 「編集前の入力に戻す」。保存できずに編集を終えたあと、取っておいた入力と入れ替える。
    /// いまの入力（保存できなかった編集）は捨てずに取っておくので、もう一度押せば元に戻る。
    func restoreStashedDraft() {
        guard !isEditing, let stash = stashedDraft else { return }
        let current = draft
        draft = stash
        stashedDraft = Self.isBlank(current) ? nil : current
        referenceError = nil
        inputMessage = stashedDraft == nil
            ? String(localized: "編集前の入力に戻しました")
            : String(localized: "編集前の入力に戻しました。直前の入力は取ってあるので、もう一度「編集前の入力に戻す」を押すと入れ替わります。")
    }

    /// restoreDraft が false なら、取っておいた編集前の入力は捨てずに残す。
    private func finishEditing(restoreDraft: Bool) {
        editingJobID = nil
        editingOriginal = nil
        if restoreDraft {
            draft = stashedDraft ?? JobDraft()
            stashedDraft = nil
        }
        referenceError = nil
    }

    /// プロンプト・スラッグ・参照画像がどれも空か。
    private static func isBlank(_ draft: JobDraft) -> Bool {
        draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.referenceImages.isEmpty
    }

    // MARK: - キューの操作

    var queueSummaryText: String {
        String(localized: "待機中 \(queued.count) 件 · 実行中 \(running.count) 件 · 並列数 \(settings.normalized().concurrency)")
    }

    var queueStateText: String {
        if isPaused {
            return isResumePending
                ? String(localized: "状態: 一時停止中（\(Self.resumeWaitingText)）")
                : String(localized: "状態: 一時停止中")
        }
        if queued.isEmpty && running.isEmpty {
            return String(localized: "状態: 実行中（待機中のジョブはありません）")
        }
        return String(localized: "状態: 実行中")
    }

    func moveUp(_ id: UUID) async {
        await queue.moveUp(id)
    }

    func moveDown(_ id: UUID) async {
        await queue.moveDown(id)
    }

    func removeQueued(_ id: UUID) async {
        let slug = slug(of: id) ?? ""
        if editingJobID == id {
            finishEditing(restoreDraft: true)
        }
        let ok = await queue.remove(id)
        if ok {
            if selectedJobID == id {
                selectedJobID = nil
            }
            queueMessage = String(localized: "待機中ジョブ「\(slug)」を削除しました")
        } else {
            queueMessage = String(localized: "「\(slug)」はもう待機中ではないため削除できませんでした")
        }
    }

    /// 「中止」。結果は `.finished` で届き、そのとき文言を「中止しました」に変える。
    func cancel(_ id: UUID) async {
        let slug = slug(of: id) ?? ""
        if running.contains(where: { $0.id == id }) {
            cancellingJobIDs.insert(id)
            queueMessage = String(localized: "「\(slug)」を中止しています…")
        } else {
            queueMessage = String(localized: "「\(slug)」はもう実行中ではありません")
        }
        await queue.cancel(id)
    }

    func pauseAll() async {
        // 待っている「再開」は取り消す。
        resumeRequest += 1
        isResumePending = false
        await queue.pause()
        queueMessage = String(localized: "キューを一時停止しました（実行中のジョブはそのまま続きます）")
    }

    /// 「再開」。追加と同じく、復元・codex のパス解決・設定の反映が終わるのを待ってから再開する
    /// （空の codex のパスで起動して、復元したジョブが全部失敗しないように）。レート制限や復元のバナーも閉じる。
    func resumeAll() async {
        resumeRequest += 1
        let request = resumeRequest
        isResumePending = true
        queueMessage = Self.resumeWaitingText
        await waitUntilQueueReady()
        guard request == resumeRequest else { return }
        isResumePending = false
        // codex が見つからないと分かったまま再開すると、待機中のジョブが全部すぐ失敗するので、一時停止のままにする。
        let codexNotFound: Bool
        switch codexCheck {
        case .missing, .invalidPath: codexNotFound = true
        default: codexNotFound = false
        }
        guard !codexNotFound else {
            queueMessage = String(localized: "codex が見つからないため、キューは一時停止のままです。設定の「codex のパス」を確かめるか「codex を探し直す」を押してから、もう一度「再開」を押してください。")
            return
        }
        rateLimitNotice = nil
        restoredNotice = nil
        await queue.resume()
        queueMessage = String(localized: "キューを再開しました")
    }

    /// 履歴の「再試行」。入力内容だけを引き継いだ新しいジョブを末尾に足す。
    func retry(_ record: JobRecord) async {
        guard !isActive(record) else {
            queueMessage = String(localized: "「\(record.slug)」はまだ実行中か待機中のため、再試行できません。終わってから押してください。")
            return
        }
        let job = record.makeRetry(now: deps.now())
        queueMessage = String(localized: "「\(record.slug)」を再試行としてキューに追加しました")
        await enqueue([job])
    }

    /// 実行中・待機中のジョブの id。
    private var activeJobIDs: Set<UUID> {
        Set(running.map(\.id) + queued.map(\.id))
    }

    /// 実行中のジョブのフォルダ（比べるための形）。
    private var runningFolderKeys: Set<String> {
        Set(running.compactMap { Self.folderKey($0.outputDir) })
    }

    /// フォルダのパスを比べるための形にする（`~` の展開と `.` `..` の整理だけ。ファイルには触らない）。空なら nil。
    private static func folderKey(_ path: String) -> String? {
        let dir = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: PathUtil.expandTilde(dir), isDirectory: true).standardizedFileURL.path
    }

    /// 履歴の行が、実行中・待機中のジョブ（同じ id か、実行中のジョブと同じフォルダ）を指しているか。
    func isActive(_ record: JobRecord) -> Bool {
        Self.isActive(record, ids: activeJobIDs, folders: runningFolderKeys)
    }

    private static func isActive(_ record: JobRecord, ids: Set<UUID>, folders: Set<String>) -> Bool {
        if ids.contains(record.id) {
            return true
        }
        guard !folders.isEmpty, let key = folderKey(record.outputDir) else { return false }
        return folders.contains(key)
    }

    // MARK: - 履歴

    func reloadHistory() {
        historyReloadDebounce?.cancel()
        historyLoadTask?.cancel()
        let directory = settings.normalized().outputDirectoryURL
        let load = deps.loadHistory
        isLoadingHistory = true
        // 読み込みでも索引に書き足すことがあるので、登録・削除と同じ鎖に並べる。
        let work = scheduleHistoryWork { load(directory) }
        historyLoadTask = Task { [weak self] in
            let records = await work.value
            guard !Task.isCancelled, let self else { return }
            self.mergeLoadedHistory(records)
            self.isLoadingHistory = false
        }
    }

    /// 履歴の索引に触る処理を、メインスレッド外で前の処理が終わってから実行する。
    /// HistoryStore は history.json を読んで書き戻すので、重なると書き足した分が消えることがある。
    @discardableResult
    private func scheduleHistoryWork<T: Sendable>(_ work: @escaping @Sendable () -> T) -> Task<T, Never> {
        let previous = historyWork
        let task = Task.detached(priority: .userInitiated) { () -> T in
            await previous?.value
            return work()
        }
        historyWork = Task { _ = await task.value }
        return task
    }

    /// 読み込んだ履歴を画面の履歴にする。
    /// - 実行中・待機中のジョブは出さない（run.json が「実行中」のままなので、読むと「中止（中断）」に見えてしまう）。
    /// - 読み込み中に終わったジョブは、読み込み結果に無くても残す。
    /// - この起動中に終わったジョブは、読んだものが古ければ（終了時刻が無い・古い）手元の記録を使う。
    private func mergeLoadedHistory(_ records: [JobRecord]) {
        var sessionRecords: [UUID: JobRecord] = [:]
        for record in history where sessionFinishedIDs.contains(record.id) {
            sessionRecords[record.id] = record
        }
        let loadedIDs = Set(records.map(\.id))
        let activeIDs = activeJobIDs
        let activeFolders = runningFolderKeys
        let extras = history.filter { record in
            sessionFinishedIDs.contains(record.id) && !loadedIDs.contains(record.id)
                && !Self.isActive(record, ids: activeIDs, folders: activeFolders)
        }
        let merged = records.compactMap { loaded -> JobRecord? in
            if Self.isActive(loaded, ids: activeIDs, folders: activeFolders) {
                return nil
            }
            if let session = sessionRecords[loaded.id], Self.isStale(loaded, comparedTo: session) {
                return session
            }
            return loaded
        }
        history = extras + merged
        if let id = selectedJobID, !history.contains(where: { $0.id == id }),
           !queued.contains(where: { $0.id == id }), !running.contains(where: { $0.id == id }) {
            selectedJobID = nil
        }
    }

    /// 読んだ記録が、この起動中に `.finished` で受け取った記録より古いか。
    static func isStale(_ loaded: JobRecord, comparedTo session: JobRecord) -> Bool {
        guard let sessionFinished = session.finishedAt else { return false }
        guard let loadedFinished = loaded.finishedAt else { return true }
        return loadedFinished < sessionFinished
    }

    /// 履歴の欄に並べる分（新しい順に historyDisplayLimit 件まで）。
    var visibleHistory: [JobRecord] {
        Array(history.prefix(historyDisplayLimit))
    }

    /// 並べていない古い履歴の件数。
    var hiddenHistoryCount: Int {
        max(0, history.count - historyDisplayLimit)
    }

    /// 「さらに表示」。
    func showMoreHistory() {
        historyDisplayLimit += Self.historyPageSize
    }

    private func scheduleHistoryReload() {
        historyReloadDebounce?.cancel()
        historyReloadDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.reloadHistory()
        }
    }

    /// 履歴の「削除」。記録ファイルだけ消して、画像は残す。
    /// 実行中のジョブのフォルダは消さない（codex が使っている最中なので）。
    func deleteHistory(_ record: JobRecord) async {
        guard !isActive(record) else {
            queueMessage = String(localized: "「\(record.slug)」はまだ実行中か待機中のため、履歴から削除できません。終わってから削除してください。")
            return
        }
        let delete = deps.deleteHistory
        let result = await scheduleHistoryWork { Result { try delete(record) } }.value
        do {
            try result.get()
            history.removeAll { $0.id == record.id }
            sessionFinishedIDs.remove(record.id)
            liveLogs[record.id] = nil
            if selectedJobID == record.id {
                selectedJobID = nil
            }
            queueMessage = String(localized: "履歴から「\(record.slug)」を削除しました（画像は残しています）")
        } catch {
            addNotice(String(localized: "履歴「\(record.slug)」を削除できませんでした: \(error.localizedDescription)"))
        }
    }

    // MARK: - 詳細

    func select(_ id: UUID?) {
        if selectedJobID != id {
            selectedJobID = id
            detailMessage = nil
        }
    }

    /// 詳細ペインに出すジョブ。実行中 → 待機中 → 履歴の順に探す。
    var selectedJob: JobRecord? {
        guard let id = selectedJobID else { return nil }
        return running.first { $0.id == id } ?? queued.first { $0.id == id } ?? history.first { $0.id == id }
    }

    func liveLog(for id: UUID) -> LiveJobLog? {
        liveLogs[id]
    }

    /// 「コマンドをコピー」。シェルにそのまま貼れる 1 行。
    func copyCommand(_ record: JobRecord) {
        deps.copyToPasteboard(record.commandLine)
        detailMessage = String(localized: "コマンドをコピーしました")
    }

    func copyPath(_ path: String) {
        deps.copyToPasteboard(path)
        detailMessage = String(localized: "パスをコピーしました: \(path)")
    }

    func openImage(_ path: String) {
        deps.openFile(URL(fileURLWithPath: path))
    }

    /// 「Finder で表示」。画像があれば画像を、なければフォルダを選んだ状態で開く。
    func revealInFinder(_ record: JobRecord) {
        let fm = FileManager.default
        let images = record.images.filter { fm.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        if !images.isEmpty {
            deps.revealInFinder(images)
            return
        }
        if !record.outputDir.isEmpty, fm.fileExists(atPath: record.outputDir) {
            deps.revealInFinder([URL(fileURLWithPath: record.outputDir, isDirectory: true)])
            return
        }
        detailMessage = record.outputDir.isEmpty
            ? String(localized: "フォルダが見つかりません: （まだ作られていません）")
            : String(localized: "フォルダが見つかりません: \(record.outputDir)")
    }

    /// 「このプロンプトを再利用」。入力欄に戻す（編集中なら編集をやめる）。
    func reusePrompt(_ record: JobRecord) {
        if isEditing {
            finishEditing(restoreDraft: false)
        }
        draft = JobFactory.draft(from: record)
        referenceError = nil
        inputMessage = String(localized: "「\(record.slug)」のプロンプトを入力欄に戻しました")
    }

    /// 終わったジョブのログをファイルから読む（メインスレッド外で）。
    func loadRunLog(for record: JobRecord) async -> LoadedRunLog {
        guard !record.outputDir.isEmpty else {
            return LoadedRunLog(raw: [], formatted: [], omittedLines: 0)
        }
        let folder = URL(fileURLWithPath: record.outputDir, isDirectory: true)
        let read = deps.readLogs
        return await Task.detached(priority: .userInitiated) {
            let logs = read(folder)
            return LoadedRunLog.make(stdout: logs.stdout, stderr: logs.stderr)
        }.value
    }

    // MARK: - バナー

    func dismissRateLimitNotice() {
        rateLimitNotice = nil
    }

    func dismissRestoredNotice() {
        restoredNotice = nil
    }

    func addNotice(_ text: String) {
        notices.append(AppNotice(text: text))
    }

    func dismissNotice(_ id: UUID) {
        notices.removeAll { $0.id == id }
    }

    // MARK: - 設定

    /// キューに渡す設定（丸めたうえで、codex のパスを実際に使うものにする）。
    var effectiveSettings: AppSettings {
        var s = settings.normalized()
        s.codexPath = effectiveCodexPath ?? ""
        return s
    }

    /// 手入力のパス（`~` 展開済み）。空なら自動検出を使う。
    var manualCodexPath: String {
        Self.expandedPath(settings.codexPath, home: deps.homeDirectory)
    }

    /// 実際に使う codex のパス。
    var effectiveCodexPath: String? {
        let manual = manualCodexPath
        return manual.isEmpty ? detectedCodexPath : manual
    }

    /// 設定欄に出す「どの codex を使うか」の説明。
    var codexPathStatusText: String {
        if !manualCodexPath.isEmpty {
            return String(localized: "入力したパスを使います: \(manualCodexPath)")
        }
        if let detectedCodexPath {
            return String(localized: "自動検出したパスを使います: \(detectedCodexPath)")
        }
        if codexCheck == .checking || codexCheck == .idle {
            return String(localized: "自動検出しています…")
        }
        return String(localized: "自動検出できませんでした。codex の絶対パスを入力してください。")
    }

    private func settingsDidChange(from old: AppSettings) {
        guard settings != old else { return }
        deps.settingsStore.save(settings)
        pushSettingsToQueue()
        // フォルダ選択・自動検出・既定に戻すなどで変わったときは、入力欄も合わせる。
        if settings.outputDirectory != old.outputDirectory {
            outputDirectoryDraft = settings.outputDirectory
            outputDirectoryError = nil
        }
        if settings.codexPath != old.codexPath {
            codexPathDraft = settings.codexPath
            codexPathError = nil
        }
        if settings.model != old.model {
            modelDraft = settings.model
            modelError = nil
        }
        if settings.instructionTemplate != old.instructionTemplate {
            templateCommitDebounce?.cancel()
            templateCommitDebounce = nil
            storedTemplateDraft = settings.instructionTemplate
        }
        if settings.codexPath != old.codexPath {
            scheduleCodexRecheck()
        }
        if settings.outputDirectory != old.outputDirectory {
            scheduleHistoryReload()
        }
    }

    // MARK: - 設定の入力欄の反映

    /// 出力ディレクトリの入力欄を確かめて反映する。だめなら理由を outputDirectoryError に出し、設定は変えない。
    @discardableResult
    func commitOutputDirectoryDraft() -> Bool {
        let value = outputDirectoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Self.outputDirectoryProblem(value, home: deps.homeDirectory) {
            outputDirectoryError = problem
            return false
        }
        outputDirectoryError = nil
        if outputDirectoryDraft != value {
            outputDirectoryDraft = value
        }
        if settings.outputDirectory != value {
            settings.outputDirectory = value
        }
        return true
    }

    /// codex のパスの入力欄を確かめて反映する。空なら自動検出。実行できるファイルでなければ反映しない。
    @discardableResult
    func commitCodexPathDraft() -> Bool {
        let value = codexPathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            let expanded = Self.expandedPath(value, home: deps.homeDirectory)
            guard expanded.hasPrefix("/"), deps.isExecutableFile(expanded) else {
                codexPathError = String(localized: "実行できる codex のファイルがありません: \(expanded)。この値は反映していません（空欄にすると自動検出したパスを使います）。")
                return false
            }
        }
        codexPathError = nil
        if codexPathDraft != value {
            codexPathDraft = value
        }
        if settings.codexPath != value {
            settings.codexPath = value
        }
        return true
    }

    /// モデルの入力欄を確かめて反映する。空なら -m を付けない。
    @discardableResult
    func commitModelDraft() -> Bool {
        let value = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains(where: { $0.isWhitespace || $0.isNewline }) {
            modelError = String(localized: "モデル名に空白や改行は入れられません。この値は反映していません。")
            return false
        }
        modelError = nil
        if modelDraft != value {
            modelDraft = value
        }
        if settings.model != value {
            settings.model = value
        }
        return true
    }

    /// 固定の指示文の入力欄をすぐ反映する（ほかの欄へ移ったときなど）。
    func commitInstructionTemplateDraft() {
        templateCommitDebounce?.cancel()
        templateCommitDebounce = nil
        if settings.instructionTemplate != storedTemplateDraft {
            settings.instructionTemplate = storedTemplateDraft
        }
    }

    /// 設定の入力欄をすべて反映する（設定を隠すときなど）。だめな値は反映せず、理由を残す。
    func commitSettingDrafts() {
        commitOutputDirectoryDraft()
        commitCodexPathDraft()
        commitModelDraft()
        commitInstructionTemplateDraft()
    }

    var isOutputDirectoryDraftPending: Bool {
        outputDirectoryDraft.trimmingCharacters(in: .whitespacesAndNewlines) != settings.outputDirectory
    }

    var isCodexPathDraftPending: Bool {
        codexPathDraft.trimmingCharacters(in: .whitespacesAndNewlines) != settings.codexPath
    }

    var isModelDraftPending: Bool {
        modelDraft.trimmingCharacters(in: .whitespacesAndNewlines) != settings.model
    }

    var isInstructionTemplateDraftPending: Bool {
        storedTemplateDraft != settings.instructionTemplate
    }

    /// 設定の入力欄に、まだ反映していない変更があるか。
    var hasPendingSettingDrafts: Bool {
        isOutputDirectoryDraftPending || isCodexPathDraftPending || isModelDraftPending || isInstructionTemplateDraftPending
    }

    /// 入力欄の下に出す「反映の仕方・状態」の文言。
    static func draftHint(pending: Bool) -> String {
        pending ? String(localized: "まだ反映していません。\(settingsCommitHint)") : settingsCommitHint
    }

    private func scheduleTemplateCommit() {
        templateCommitDebounce?.cancel()
        templateCommitDebounce = Task { [weak self] in
            try? await Task.sleep(for: Self.templateCommitDelay)
            guard !Task.isCancelled else { return }
            self?.commitInstructionTemplateDraft()
        }
    }

    /// 出力ディレクトリとして使えない理由。使えるなら nil（空は既定の場所を使う）。
    static func outputDirectoryProblem(_ value: String, home: URL) -> String? {
        guard !value.isEmpty else { return nil }
        if value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return String(localized: "改行などの制御文字を含むパスは使えません。この値は反映していません。")
        }
        let expanded = ReferenceImageValidator.expandTilde(value, home: home)
        guard expanded.hasPrefix("/") else {
            return String(localized: "「/」か「~/」から始まるフォルダのパスを入力してください（例: \(AppSettings.defaultOutputDirectory)）。この値は反映していません。")
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), !isDirectory.boolValue {
            return String(localized: "フォルダではなくファイルがあります: \(expanded)。この値は反映していません。")
        }
        return nil
    }

    // MARK: - 設定の表示

    /// 「設定を表示」（バナー・⌘,）。開いて、設定の位置までスクロールさせる。
    func showSettings() {
        isSettingsVisible = true
        settingsScrollRequest += 1
    }

    /// 入力の列の上にある「設定を表示」「設定を隠す」。隠すときは入力欄の内容を反映する。
    func toggleSettings() {
        if isSettingsVisible {
            commitSettingDrafts()
            isSettingsVisible = false
        } else {
            showSettings()
        }
    }

    /// 変わっていればキューへ渡す。前の反映が終わってから次を渡す。
    private func pushSettingsToQueue() {
        let s = effectiveSettings
        guard s != lastPushedSettings else { return }
        lastPushedSettings = s
        let q = queue
        let previous = settingsPush
        settingsPush = Task {
            await previous?.value
            await q.updateSettings(s)
        }
    }

    private func applyTimeoutText() {
        let text = storedTimeoutText
            .applyingTransform(.fullwidthToHalfwidth, reverse: false)?
            .trimmingCharacters(in: .whitespaces) ?? storedTimeoutText
        guard let minutes = Double(text), minutes.isFinite, minutes > 0 else {
            timeoutError = String(localized: "分を数字で入力してください（例: 10）。")
            return
        }
        guard minutes <= 24 * 60 else {
            timeoutError = String(localized: "1440 分（24 時間）以下にしてください。")
            return
        }
        let seconds = Int((minutes * 60).rounded())
        guard seconds >= AppSettings.minimumTimeoutSeconds else {
            timeoutError = String(localized: "0.5 分（30 秒）以上にしてください。")
            return
        }
        timeoutError = nil
        if settings.timeoutSeconds != seconds {
            settings.timeoutSeconds = seconds
        }
    }

    /// 固定の指示文の「既定に戻す」。
    func resetInstructionTemplate() {
        templateCommitDebounce?.cancel()
        templateCommitDebounce = nil
        storedTemplateDraft = AppSettings.defaultInstructionTemplate
        settings.instructionTemplate = AppSettings.defaultInstructionTemplate
    }

    /// 「Finder で開く」。出力ディレクトリが無ければ作る。
    func openOutputDirectory() {
        let url = settings.normalized().outputDirectoryURL
        do {
            try deps.createDirectory(url)
            deps.openFile(url)
        } catch {
            addNotice(String(localized: "出力ディレクトリを開けませんでした: \(url.path)（\(error.localizedDescription)）"))
        }
    }

    /// フォルダ選択ダイアログで選んだ場所を入れる（ホーム配下は `~` で表す）。入力欄の書きかけは捨てる。
    func setOutputDirectory(_ url: URL) {
        let path = url.standardizedFileURL.path
        let home = deps.homeDirectory.standardizedFileURL.path
        let value: String
        if path == home {
            value = "~"
        } else if path.hasPrefix(home + "/") {
            value = "~/" + path.dropFirst(home.count + 1)
        } else {
            value = path
        }
        outputDirectoryDraft = value
        outputDirectoryError = nil
        settings.outputDirectory = value
    }

    // MARK: - codex の確認

    /// codex のパスを解決し直して、ログイン状態を確認する。
    func recheckCodex(invalidate: Bool) {
        codexRecheckDebounce?.cancel()
        codexCheckTask?.cancel()
        codexCheck = .checking
        let gate = startupGate
        let resolution = Task { [weak self] in
            await gate?.value
            await self?.resolveCodexPath(invalidate: invalidate)
        }
        pathResolution = resolution
        codexCheckTask = Task { [weak self] in
            await resolution.value
            guard !Task.isCancelled else { return }
            await self?.checkLogin()
        }
    }

    /// 「ログイン状態を再確認」。見つかっていなければ検出からやり直す。
    func recheckLogin() {
        recheckCodex(invalidate: detectedCodexPath == nil)
    }

    /// 「自動検出」。手入力のパスを空にして、ログインシェルで探し直す。
    func autoDetectCodexPath() {
        codexPathDraft = ""
        codexPathError = nil
        if !settings.codexPath.isEmpty {
            settings.codexPath = ""
        }
        recheckCodex(invalidate: true)
    }

    private func scheduleCodexRecheck() {
        codexRecheckDebounce?.cancel()
        codexRecheckDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.recheckCodex(invalidate: false)
        }
    }

    private func resolveCodexPath(invalidate: Bool) async {
        if invalidate {
            await deps.invalidateCodexDetection()
        }
        let detected = await deps.detectCodexPath()
        if detectedCodexPath != detected {
            detectedCodexPath = detected
        }
        pushSettingsToQueue()
    }

    private func checkLogin() async {
        let manual = manualCodexPath
        let path: String
        if !manual.isEmpty {
            guard deps.isExecutableFile(manual) else {
                codexCheck = .invalidPath(manual)
                return
            }
            path = manual
        } else if let detected = detectedCodexPath {
            path = detected
        } else {
            codexCheck = .missing
            return
        }
        codexCheck = .checking
        let environment = await deps.codexEnvironment()
        let status = await deps.loginStatus(path, environment)
        guard !Task.isCancelled else { return }
        codexCheck = Self.checkState(for: status, path: path)
    }

    /// `codex login status` の結果を画面の状態にする。
    /// 終了コードが無い（起動できない・時間内に終わらない）ときはログインの問題ではないので、ログインの案内は出さない。
    static func checkState(for status: LoginStatus, path: String) -> CodexCheckState {
        let output = status.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if status.loggedIn {
            return .loggedIn(path: path, output: output)
        }
        guard status.exitCode != nil else {
            return .launchFailed(path: path, output: output)
        }
        return .notLoggedIn(path: path, output: output)
    }

    /// 「codex を探し直す」。覚えた検出結果を捨て、ログインシェルで探してからログイン状態を確かめる。
    func rediscoverCodex() {
        recheckCodex(invalidate: true)
    }

    // MARK: - 補助

    static func expandedPath(_ raw: String, home: URL) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return ReferenceImageValidator.expandTilde(trimmed, home: home)
    }

    /// 秒をタイムアウト欄の分表記にする（600 → "10"、90 → "1.5"）。
    static func minutesText(fromSeconds seconds: Int) -> String {
        if seconds % 60 == 0 {
            return String(seconds / 60)
        }
        return String(format: "%g", Double(seconds) / 60)
    }
}
