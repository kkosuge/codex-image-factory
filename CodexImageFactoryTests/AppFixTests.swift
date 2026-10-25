import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexImageFactory

/// レビューで見つかった AppModel・UI の不具合の再発防止。

// MARK: - 履歴の再読み込みと実行中のジョブ

@Suite("AppFix 履歴と実行中のジョブ")
@MainActor
struct AppFixHistoryTests {
    /// 実行中のジョブの run.json（status: running）を HistoryStore が読むとこうなる。
    static func interruptedCopy(of running: JobRecord) -> JobRecord {
        var record = running
        HistoryStore.fixUp(&record, folder: URL(fileURLWithPath: running.outputDir, isDirectory: true))
        return record
    }

    static func runningJob(slug: String, in home: URL) -> JobRecord {
        var job = uitRecord(status: .running, slug: slug)
        job.outputDir = home.appendingPathComponent("20261025-000000-\(slug)", isDirectory: true).path
        return job
    }

    @Test func reloadWhileRunningDoesNotListTheRunningJob() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let running = Self.runningJob(slug: "live", in: h.home)
        let ghost = Self.interruptedCopy(of: running)
        #expect(ghost.status == .cancelled)
        let older = uitRecord(status: .done, slug: "older")
        h.historyRecords = [ghost, older]
        let model = h.makeModel()
        model.handle(.snapshot(QueueSnapshot(queued: [], running: [running], isPaused: false, concurrency: 3)))

        model.reloadHistory()
        #expect(await uitWaitUntil { !model.isLoadingHistory })

        #expect(model.history.map(\.id) == [older.id])
        #expect(model.running.map(\.id) == [running.id])
    }

    @Test func deleteAndRetryAreRefusedForARunningJob() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        let running = Self.runningJob(slug: "busy", in: h.home)
        model.handle(.snapshot(QueueSnapshot(queued: [], running: [running], isPaused: false, concurrency: 3)))
        let ghost = Self.interruptedCopy(of: running)

        await model.deleteHistory(ghost)
        #expect(model.queueMessage?.contains("履歴から削除できません") == true)
        await model.retry(ghost)
        #expect(model.queueMessage?.contains("再試行できません") == true)

        // id が違っても、実行中のジョブと同じフォルダなら消さない。
        var sameFolder = ghost
        sameFolder.id = UUID()
        await model.deleteHistory(sameFolder)
        #expect(model.queueMessage?.contains("履歴から削除できません") == true)

        try await Task.sleep(for: .milliseconds(50))
        #expect(h.deleted.all.isEmpty)
        #expect(h.queue.current.enqueued.isEmpty)

        // 終わったあとなら消せる。
        model.handle(.snapshot(QueueSnapshot(queued: [], running: [], isPaused: false, concurrency: 3)))
        await model.deleteHistory(ghost)
        #expect(h.deleted.all.map(\.id) == [ghost.id])
    }

    @Test func aJobFinishingDuringTheLoadKeepsItsFinishedRecord() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let running = Self.runningJob(slug: "racing", in: h.home)
        let stale = Self.interruptedCopy(of: running)
        let loadStarted = UITRecorder<Bool>()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var deps = h.dependencies()
        deps.loadHistory = { _ in
            loadStarted.append(true)
            release.wait()
            return [stale]
        }
        let model = AppModel(dependencies: deps)
        model.handle(.snapshot(QueueSnapshot(queued: [], running: [running], isPaused: false, concurrency: 3)))

        // 読み込みが run.json（実行中）を読んだあとで、ジョブが終わる。
        model.reloadHistory()
        #expect(await uitWaitUntil { loadStarted.all.count == 1 })
        var finished = running
        finished.status = .done
        finished.finishedAt = running.startedAt?.addingTimeInterval(40)
        finished.images = [running.outputDir + "/racing-01.png"]
        model.handle(.finished(finished))
        model.handle(.snapshot(QueueSnapshot(queued: [], running: [], isPaused: false, concurrency: 3)))
        release.signal()
        #expect(await uitWaitUntil { !model.isLoadingHistory })

        #expect(model.history.count == 1)
        #expect(model.history.first?.status == .done)
        #expect(model.history.first?.images.count == 1)
    }

    @Test func staleCopiesAreRecognised() {
        var session = uitRecord(status: .done, slug: "s")
        var loaded = session
        #expect(!AppModel.isStale(loaded, comparedTo: session))
        loaded.finishedAt = nil
        #expect(AppModel.isStale(loaded, comparedTo: session))
        loaded.finishedAt = session.finishedAt?.addingTimeInterval(-5)
        #expect(AppModel.isStale(loaded, comparedTo: session))
        session.finishedAt = nil
        #expect(!AppModel.isStale(loaded, comparedTo: session))
    }

    @Test func historyIsShownInPages() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let base = Date(timeIntervalSince1970: 1_793_000_000)
        h.historyRecords = (0..<650).map { uitRecord(slug: "h\($0)", createdAt: base.addingTimeInterval(-Double($0))) }
        let model = h.makeModel()
        model.reloadHistory()
        #expect(await uitWaitUntil { model.history.count == 650 && !model.isLoadingHistory })
        #expect(model.visibleHistory.count == AppModel.historyPageSize)
        #expect(model.visibleHistory.first?.slug == "h0")
        #expect(model.hiddenHistoryCount == 350)
        model.showMoreHistory()
        #expect(model.visibleHistory.count == 600)
        #expect(model.hiddenHistoryCount == 50)
        model.showMoreHistory()
        #expect(model.visibleHistory.count == 650)
        #expect(model.hiddenHistoryCount == 0)
    }
}

// MARK: - 再開・追加の順番・終了

@Suite("AppFix 再開と追加の順番")
@MainActor
struct AppFixQueueGateTests {
    @Test func resumeWaitsForTheCodexPath() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        h.savedQueue = [uitRecord(status: .queued, slug: "a"), uitRecord(status: .queued, slug: "b")]
        h.detectDelay = .milliseconds(800)
        let model = h.makeModel()
        model.start()
        #expect(await uitWaitUntil { model.restoredNotice != nil })

        let resume = Task { await model.resumeAll() }
        #expect(await uitWaitUntil { model.isResumePending })
        #expect(h.queue.current.resumeCount == 0)
        #expect(model.queueMessage == AppModel.resumeWaitingText)
        #expect(model.queueStateText.contains("codex の場所を確認しています"))
        #expect(model.restoredNotice != nil)

        await resume.value
        #expect(!model.isResumePending)
        #expect(model.restoredNotice == nil)
        #expect(model.queueMessage == "キューを再開しました")
        let calls = h.queue.current.calls
        let settingsIndex = try #require(calls.firstIndex(of: "settings:/fake/bin/codex"))
        let resumeIndex = try #require(calls.firstIndex(of: "resume"))
        #expect(settingsIndex < resumeIndex)
    }

    @Test func pausingWhileTheResumeWaitsCancelsIt() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        h.savedQueue = [uitRecord(status: .queued, slug: "a")]
        h.detectDelay = .milliseconds(800)
        let model = h.makeModel()
        model.start()
        #expect(await uitWaitUntil { model.restoredNotice != nil })
        let resume = Task { await model.resumeAll() }
        #expect(await uitWaitUntil { model.isResumePending })
        await model.pauseAll()
        #expect(!model.isResumePending)
        await resume.value
        #expect(h.queue.current.resumeCount == 0)
        #expect(model.isPaused)
    }

    @Test func addsWhileTheGateIsPendingKeepTheirOrder() async throws {
        // 入れ替わりは毎回は起きないので、何回か繰り返して確かめる。
        for _ in 0..<3 {
            let h = try UITHarness()
            defer { h.cleanUp() }
            h.detectDelay = .milliseconds(400)
            let model = h.makeModel()
            model.start()
            var adds: [Task<Void, Never>] = []
            for i in 1...6 {
                model.draft.prompt = "プロンプト \(i)"
                model.draft.slug = "s\(i)"
                adds.append(Task { await model.addSingle() })
                #expect(await uitWaitUntil { model.draft.prompt.isEmpty })
                try await Task.sleep(for: .milliseconds(10))
            }
            for add in adds {
                await add.value
            }
            let slugs = h.queue.current.enqueued.flatMap { $0.map(\.slug) }
            #expect(slugs == ["s1", "s2", "s3", "s4", "s5", "s6"])
            // どれも codex のパスを渡したあとで追加している。
            let calls = h.queue.current.calls
            let settingsIndex = try #require(calls.firstIndex(of: "settings:/fake/bin/codex"))
            let firstEnqueue = try #require(calls.firstIndex(of: "enqueue:1"))
            #expect(settingsIndex < firstEnqueue)
        }
    }

    @Test func quittingWhileAnAddWaitsStillQueuesTheJob() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        h.detectDelay = .milliseconds(1500)
        let model = h.makeModel()
        model.start()
        model.draft.prompt = "終了直前に追加"
        model.draft.slug = "waiting"
        let add = Task { await model.addSingle() }
        #expect(await uitWaitUntil { model.draft.prompt.isEmpty })
        #expect(h.queue.current.enqueued.isEmpty)
        #expect(model.needsGracefulShutdown)

        await model.shutdown()

        #expect(h.queue.current.enqueued.flatMap { $0 }.map(\.slug) == ["waiting"])
        #expect(Array(h.queue.current.calls.suffix(3)) == ["pause", "enqueue:1", "shutdown"])
        // 待っていた追加が後から二重に渡すことはない。
        await add.value
        #expect(h.queue.current.enqueued.count == 1)
    }
}

// MARK: - 設定の入力欄

@Suite("AppFix 設定の入力欄")
@MainActor
struct AppFixSettingsDraftTests {
    @Test func typingDoesNotReachTheQueueOrTheSavedSettings() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        await model.waitUntilQueueReady()
        let pushedBefore = h.queue.current.settings.count

        for partial in ["~", "~/", "~/D", "~/De", "~/Desktop/o"] {
            model.outputDirectoryDraft = partial
        }
        for partial in ["/", "/o", "/opt/ho"] {
            model.codexPathDraft = partial
        }
        for partial in ["g", "gpt", "gpt-5"] {
            model.modelDraft = partial
        }
        await model.waitUntilQueueReady()

        #expect(h.queue.current.settings.count == pushedBefore)
        #expect(model.settings.outputDirectory == AppSettings.defaultOutputDirectory)
        #expect(model.settings.codexPath == "")
        #expect(model.settings.model == "")
        let stored = SettingsStore(defaults: h.suite.defaults).load()
        #expect(stored.outputDirectory == AppSettings.defaultOutputDirectory)
        #expect(stored.codexPath == "")
        #expect(stored.model == "")
        #expect(model.isOutputDirectoryDraftPending)
        #expect(model.hasPendingSettingDrafts)
        #expect(AppModel.draftHint(pending: true).hasPrefix("まだ反映していません"))

        // Return（またはほかの欄へ移る）で反映する。
        model.outputDirectoryDraft = "  ~/Desktop/out  "
        #expect(model.commitOutputDirectoryDraft())
        model.modelDraft = "gpt-5.5"
        #expect(model.commitModelDraft())
        model.codexPathDraft = ""
        #expect(model.commitCodexPathDraft())
        await model.waitUntilQueueReady()

        #expect(model.outputDirectoryDraft == "~/Desktop/out")
        #expect(model.settings.outputDirectory == "~/Desktop/out")
        #expect(!model.hasPendingSettingDrafts)
        let pushed = h.queue.current.settings
        #expect(pushed.allSatisfy { [AppSettings.defaultOutputDirectory, "~/Desktop/out"].contains($0.outputDirectory) })
        #expect(pushed.allSatisfy { ["", "gpt-5.5"].contains($0.model) })
        #expect(pushed.last?.outputDirectory == "~/Desktop/out")
        #expect(pushed.last?.model == "gpt-5.5")
        let saved = SettingsStore(defaults: h.suite.defaults).load()
        #expect(saved.outputDirectory == "~/Desktop/out")
        #expect(saved.model == "gpt-5.5")
    }

    @Test func invalidValuesShowAReasonAndAreNotApplied() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let codex = h.home.appendingPathComponent("bin/codex").path
        h.executablePaths = [codex]
        let file = try h.makeFile("not-a-folder.png")
        let model = h.makeModel()
        await model.waitUntilQueueReady()

        model.outputDirectoryDraft = "relative/out"
        #expect(!model.commitOutputDirectoryDraft())
        #expect(model.outputDirectoryError?.contains("「/」か「~/」から始まる") == true)
        model.outputDirectoryDraft = file.path
        #expect(!model.commitOutputDirectoryDraft())
        #expect(model.outputDirectoryError?.contains("ファイルがあります") == true)
        #expect(model.settings.outputDirectory == AppSettings.defaultOutputDirectory)

        model.codexPathDraft = "/opt/ho"
        #expect(!model.commitCodexPathDraft())
        #expect(model.codexPathError?.contains("実行できる codex のファイルがありません: /opt/ho") == true)
        model.codexPathDraft = h.home.path
        #expect(!model.commitCodexPathDraft())
        #expect(model.settings.codexPath == "")

        model.modelDraft = "gpt 5"
        #expect(!model.commitModelDraft())
        #expect(model.modelError != nil)
        #expect(model.settings.model == "")

        await model.waitUntilQueueReady()
        #expect(h.queue.current.settings.allSatisfy { $0.outputDirectory == AppSettings.defaultOutputDirectory && $0.model == "" })
        #expect(h.queue.current.settings.allSatisfy { $0.codexPath != "/opt/ho" && $0.codexPath != h.home.path })

        // 直せばエラーは消えて反映される。
        model.codexPathDraft = "~/bin/codex"
        #expect(model.commitCodexPathDraft())
        #expect(model.codexPathError == nil)
        #expect(model.settings.codexPath == "~/bin/codex")
        #expect(model.manualCodexPath == codex)
        model.outputDirectoryDraft = "~/Pictures/Out"
        #expect(model.commitOutputDirectoryDraft())
        #expect(model.outputDirectoryError == nil)
    }

    @Test func instructionTemplateIsAppliedOnceTypingSettles() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        await model.waitUntilQueueReady()
        let before = h.queue.current.settings.count

        model.instructionTemplateDraft = "独"
        model.instructionTemplateDraft = "独自の"
        model.instructionTemplateDraft = "独自の指示 {count}"
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.settings.instructionTemplate == AppSettings.defaultInstructionTemplate)
        #expect(h.queue.current.settings.count == before)
        #expect(model.isInstructionTemplateDraftPending)

        #expect(await uitWaitUntil { model.settings.instructionTemplate == "独自の指示 {count}" })
        await model.waitUntilQueueReady()
        #expect(h.queue.current.settings.dropFirst(before).map(\.instructionTemplate) == ["独自の指示 {count}"])
        #expect(SettingsStore(defaults: h.suite.defaults).load().instructionTemplate == "独自の指示 {count}")
        #expect(!model.isInstructionTemplateDraftPending)

        // ほかの欄へ移ったときはすぐ反映する。
        model.instructionTemplateDraft = "すぐ反映"
        model.commitInstructionTemplateDraft()
        #expect(model.settings.instructionTemplate == "すぐ反映")

        // 既定に戻すと入力欄も戻る。
        model.instructionTemplateDraft = "書きかけ"
        model.resetInstructionTemplate()
        #expect(model.instructionTemplateDraft == AppSettings.defaultInstructionTemplate)
        #expect(model.settings.instructionTemplate == AppSettings.defaultInstructionTemplate)

        // 終了の直前に、反映を待っている分を保存する。
        model.instructionTemplateDraft = "終了前の指示"
        model.flushPendingSettingsEdits()
        #expect(SettingsStore(defaults: h.suite.defaults).load().instructionTemplate == "終了前の指示")
    }

    @Test func draftsFollowChangesMadeElsewhere() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.outputDirectoryDraft = "~/書きかけ"
        model.setOutputDirectory(h.home.appendingPathComponent("Pictures/Out", isDirectory: true))
        #expect(model.outputDirectoryDraft == "~/Pictures/Out")
        #expect(model.settings.outputDirectory == "~/Pictures/Out")

        model.codexPathDraft = "/bad/codex"
        #expect(!model.commitCodexPathDraft())
        model.autoDetectCodexPath()
        #expect(model.codexPathDraft == "")
        #expect(model.codexPathError == nil)

        // 設定を開くとスクロールを頼む。隠すときは入力欄を反映する。
        #expect(!model.isSettingsVisible)
        model.showSettings()
        #expect(model.isSettingsVisible)
        #expect(model.settingsScrollRequest == 1)
        model.outputDirectoryDraft = "~/閉じる前"
        model.toggleSettings()
        #expect(!model.isSettingsVisible)
        #expect(model.settings.outputDirectory == "~/閉じる前")
        model.toggleSettings()
        #expect(model.isSettingsVisible)
        #expect(model.settingsScrollRequest == 2)
    }

    @Test func settingsFieldsBindToDraftsAndCommitOnReturn() throws {
        let text = try AppFixSource.read("UI/SettingsSection.swift")
        for field in ["outputDirectory", "codexPath", "model", "instructionTemplate"] {
            #expect(!text.contains("$model.settings.\(field)"), "\(field) を設定に直接つないでいる")
        }
        for draft in ["outputDirectoryDraft", "codexPathDraft", "modelDraft", "instructionTemplateDraft"] {
            #expect(text.contains("$model.\(draft)"), "\(draft) を使っていない")
        }
        #expect(text.components(separatedBy: ".onSubmit").count - 1 >= 3)
        #expect(text.components(separatedBy: ".focused($focus").count - 1 >= 4)
        #expect(text.contains("onChange(of: focus)"))
        // 反映の仕方（Return かほかの欄へ移る）を文字で出している。
        #expect(text.contains("AppModel.draftHint("))
    }
}

// MARK: - 編集中のジョブが動き出したとき

@Suite("AppFix 待機中ジョブの編集")
@MainActor
struct AppFixEditingTests {
    @Test func savingAfterTheJobStartedKeepsTheEditsAndTheEarlierDraft() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.draft.prompt = "元のプロンプト"
        model.draft.slug = "edit-me"
        await model.addSingle()
        let job = try #require(h.queue.current.enqueued.first?.first)
        #expect(await uitWaitUntil { model.queued.count == 1 })

        model.draft.prompt = "書きかけの別のプロンプト"
        model.beginEditing(job.id)
        model.draft.prompt = "書き直したプロンプト"

        // 編集している間に実行が始まる。
        var started = job
        started.status = .running
        started.startedAt = Date()
        h.queue.state.withLock {
            $0.queued = []
            $0.running = [started]
        }
        model.handle(.snapshot(QueueSnapshot(queued: [], running: [started], isPaused: false, concurrency: 3)))
        #expect(model.isEditing)
        #expect(model.editingJob == nil)
        #expect(model.canSaveEdit)
        #expect(model.editingStatusText?.contains("編集した内容を入力欄に残したまま編集を終えます") == true)

        await model.saveEdit()

        #expect(!model.isEditing)
        #expect(model.draft.prompt == "書き直したプロンプト")
        #expect(h.queue.current.updates.isEmpty)
        #expect(model.inputMessage?.contains("新しいジョブとして追加できます") == true)
        #expect(model.inputMessage?.contains("「編集前の入力に戻す」") == true)
        #expect(model.canRestoreStashedDraft)

        // 新しいジョブとして足してから、編集前の入力に戻す。
        await model.addSingle()
        #expect(h.queue.current.enqueued.last?.first?.prompt == "書き直したプロンプト")
        model.restoreStashedDraft()
        #expect(model.draft.prompt == "書きかけの別のプロンプト")
        #expect(!model.canRestoreStashedDraft)
    }

    @Test func switchingToAnotherJobDoesNotDropUnsavedEdits() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.draft.prompt = "A のプロンプト\n\nB のプロンプト"
        model.draft.slug = "pair"
        await model.addBatch()
        let jobs = try #require(h.queue.current.enqueued.first)
        #expect(await uitWaitUntil { model.queued.count == 2 })
        model.draft.prompt = "まだ送っていない入力"

        model.beginEditing(jobs[0].id)
        model.draft.prompt = "A を直した"
        model.beginEditing(jobs[1].id)
        #expect(model.editingJobID == jobs[0].id)
        #expect(model.draft.prompt == "A を直した")
        #expect(model.inputMessage?.contains("「変更を保存」か「編集をやめる」") == true)

        // 変更が無ければ切り替えられる。編集前の入力はそのまま取っておく。
        model.cancelEditing()
        #expect(model.draft.prompt == "まだ送っていない入力")
        model.beginEditing(jobs[0].id)
        model.beginEditing(jobs[1].id)
        #expect(model.editingJobID == jobs[1].id)
        model.cancelEditing()
        #expect(model.draft.prompt == "まだ送っていない入力")
    }
}

// MARK: - 中止・codex の起動失敗

@Suite("AppFix 中止と codex の確認")
@MainActor
struct AppFixCancelAndCodexTests {
    @Test func cancelMessageIsReplacedWhenTheJobFinishes() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        let running = uitRecord(status: .running, slug: "stop-me")
        model.handle(.snapshot(QueueSnapshot(queued: [], running: [running], isPaused: false, concurrency: 3)))

        await model.cancel(running.id)
        #expect(model.queueMessage == "「stop-me」を中止しています…")
        var finished = running
        finished.status = .cancelled
        finished.finishedAt = running.startedAt?.addingTimeInterval(3)
        model.handle(.finished(finished))
        #expect(model.queueMessage == "「stop-me」を中止しました")

        await model.cancel(running.id)
        #expect(model.queueMessage == "「stop-me」はもう実行中ではありません")
    }

    @Test func launchFailureIsNotReportedAsNotLoggedIn() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        h.login = LoginStatus(
            loggedIn: false,
            output: "codex を起動できませんでした（/usr/bin）。設定で codex のパスを確認してください。\nフォルダは実行できません: /usr/bin",
            exitCode: nil
        )
        let model = h.makeModel()
        model.start()
        #expect(await uitWaitUntil {
            if case .launchFailed = model.codexCheck { true } else { false }
        })
        #expect(model.codexCheck.label.hasPrefix("codex を起動できません"))

        #expect(AppModel.checkState(for: LoginStatus(loggedIn: false, output: "Not logged in\n", exitCode: 1), path: "/c")
            == .notLoggedIn(path: "/c", output: "Not logged in"))
        #expect(AppModel.checkState(for: LoginStatus(loggedIn: false, output: "env: node: No such file or directory", exitCode: 127), path: "/c")
            == .notLoggedIn(path: "/c", output: "env: node: No such file or directory"))
        #expect(AppModel.checkState(for: LoginStatus(loggedIn: false, output: "15 秒以内に終わりませんでした", exitCode: nil), path: "/c")
            == .launchFailed(path: "/c", output: "15 秒以内に終わりませんでした"))
        #expect(AppModel.checkState(for: LoginStatus(loggedIn: true, output: "Logged in", exitCode: 0), path: "/c")
            == .loggedIn(path: "/c", output: "Logged in"))
    }

    @Test func liveDependenciesTreatAFolderAsNotExecutable() {
        let deps = AppDependencies.live()
        #expect(!deps.isExecutableFile("/usr/bin"))
        #expect(!deps.isExecutableFile(NSTemporaryDirectory()))
        #expect(deps.isExecutableFile("/bin/sh"))
    }

    @Test func rowLabelsIncludeThePosition() {
        #expect(UIDisplayFormat.rowControlLabel("削除", position: UIDisplayFormat.queuePosition(1), slug: "kina-mascot") == "削除: 2 番目 kina-mascot")
        #expect(UIDisplayFormat.rowControlLabel("再試行", position: UIDisplayFormat.historyPosition(2), slug: "kina-mascot") == "再試行: 履歴 3 番目 kina-mascot")
    }
}

// MARK: - 画面（スクロール・最小サイズ）
// プロセス内から読めるアクセシビリティツリーには SwiftUI のボタンや行がほとんど出てこないので（UIAuditTests の説明を参照）、
// 行やボタンのラベル・識別子はソースの検査と表示用の関数のテストで確かめる。

@Suite("AppFix 画面", .serialized)
@MainActor
struct AppFixScreenTests {
    @Test func showSettingsScrollsTheSettingsIntoView() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        let (window, hosting) = UIAuditTests.makeWindow(ContentView(model: model))
        defer { window.close() }
        try await UIAuditTests.settle(hosting)
        let scroll = try #require(Self.inputScrollView(in: hosting))
        #expect(scroll.contentView.bounds.origin.y < 1)

        model.showSettings()
        try await UIAuditTests.settle(hosting)
        #expect(await uitWaitUntil(timeout: .seconds(3)) {
            hosting.layoutSubtreeIfNeeded()
            return scroll.contentView.bounds.origin.y > 100
        }, "設定を開いてもスクロールしていない: \(scroll.contentView.bounds)")
    }

    @Test func minimumSizeFitsA1440x900ScreenWithTheDock() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        h.detectedPath = nil
        h.savedQueue = [uitRecord(status: .queued, slug: "restored")]
        let model = h.makeModel()
        // バナーを何枚か出した状態でも小さくできること。
        let controller = NSHostingController(rootView: ContentView(model: model))
        let window = NSWindow(contentViewController: controller)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        defer { window.close() }
        #expect(await uitWaitUntil(timeout: .seconds(5)) { model.codexCheck == .missing && model.restoredNotice != nil })
        model.addNotice("お知らせ")
        try await UIAuditTests.settle(controller.view)
        let minimum = controller.sizeThatFits(in: CGSize(width: 10, height: 10))
        // 1440×900・メニューバー 24・Dock 約 70 で、見える高さは約 806（タイトルバー 28 を含む）。
        #expect(minimum.height <= 700, "最小の高さ: \(minimum.height)")
        #expect(minimum.width <= 1280, "最小の幅: \(minimum.width)")
        #expect(ContentView.minimumSize.height <= 700)
    }

    /// 入力の列（いちばん左）の NSScrollView。
    static func inputScrollView(in root: NSView) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView {
                found.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
            .filter { $0.frame.height > 200 }
            .min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }
}

// MARK: - ソースの検査

enum AppFixSource {
    static func read(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodexImageFactory", isDirectory: true)
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}

@Suite("AppFix ソース")
struct AppFixSourceTests {
    @Test func queueAndHistoryRowsAreEagerAndLabelledWithTheirPosition() throws {
        let text = try AppFixSource.read("UI/QueueHistoryColumn.swift")
        #expect(!text.contains("LazyVStack"), "画面外の行がツリーに出ない")
        // 行のボタンのラベルをスラッグだけで作らない（同じスラッグの行を見分けられない）。
        let slugOnly = #"axControl\("[^"]*: \\\((job|record)\.slug\)""#
        #expect(text.range(of: slugOnly, options: .regularExpression) == nil)
        #expect(text.contains("rowControlLabel"))
        // 履歴は区切って並べ、残りは「さらに表示」で出す。
        #expect(text.contains("model.visibleHistory"))
        #expect(text.contains("id: \"history.showMore\""))
    }

    @Test func launchFailureHasItsOwnBanner() throws {
        let banners = try AppFixSource.read("UI/BannerViews.swift")
        let start = try #require(banners.range(of: "case .launchFailed"))
        let end = try #require(banners.range(of: "case .notLoggedIn"))
        let section = banners[start.lowerBound..<end.lowerBound]
        #expect(section.contains("banner.codexLaunch"))
        #expect(section.contains("codex を探し直す"))
        #expect(!section.contains("codex login を実行"))
    }

    @Test func settingsToggleIsOutsideTheScrollView() throws {
        let input = try AppFixSource.read("UI/InputColumn.swift")
        let section = try AppFixSource.read("UI/SettingsSection.swift")
        #expect(input.contains("id: \"settings.toggle\""))
        #expect(!section.contains("id: \"settings.toggle\""))
        #expect(input.contains("ScrollViewReader"))
        #expect(input.contains("scrollTo("))
        let banners = try AppFixSource.read("UI/BannerViews.swift")
        #expect(!banners.contains("isSettingsVisible = true"))
        let app = try AppFixSource.read("App/CodexImageFactoryApp.swift")
        #expect(app.contains("showSettings()"))
    }
}
