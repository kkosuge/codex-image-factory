import Foundation
import Testing
@testable import CodexImageFactory

/// 修正後の検証で見つかった残りの問題のテスト。
@Suite("FinalFix", .serialized)
@MainActor
struct FinalFixTests {
    @Test func resumeStaysPausedWhenCodexIsNotFound() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        h.savedQueue = [uitRecord(status: .queued, slug: "a"), uitRecord(status: .queued, slug: "b")]
        h.detectedPath = nil
        let model = h.makeModel()
        model.start()
        #expect(await uitWaitUntil { model.restoredNotice != nil })

        await model.resumeAll()
        #expect(h.queue.current.resumeCount == 0, "codex が無いまま再開すると全部失敗する")
        #expect(model.queueMessage?.contains("codex が見つからないため") == true)
        #expect(!model.isResumePending)
    }

    @Test func restoringTheStashSwapsInsteadOfDiscarding() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.draft.prompt = "元のプロンプト"
        await model.addSingle()
        let job = try #require(h.queue.current.enqueued.first?.first)
        #expect(await uitWaitUntil { model.queued.count == 1 })

        model.draft.prompt = "書きかけ"
        model.beginEditing(job.id)
        model.draft.prompt = "書き直し"
        // 編集中に実行が始まり、保存できずに編集を終える。
        var started = job
        started.status = .running
        model.handle(.snapshot(QueueSnapshot(queued: [], running: [started], isPaused: false, concurrency: 3)))
        await model.saveEdit()
        #expect(model.draft.prompt == "書き直し")

        // 「編集前の入力に戻す」を先に押しても、書き直した内容は消えない（もう一度押すと戻る）。
        model.restoreStashedDraft()
        #expect(model.draft.prompt == "書きかけ")
        #expect(model.canRestoreStashedDraft)
        model.restoreStashedDraft()
        #expect(model.draft.prompt == "書き直し")
    }

    @Test func editingIsRefusedWhileAStashAndAnInputBothExist() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.draft.prompt = "一つ目"
        await model.addSingle()
        model.draft.prompt = "二つ目"
        await model.addSingle()
        let jobs = h.queue.current.enqueued.flatMap { $0 }
        #expect(jobs.count == 2)
        #expect(await uitWaitUntil { model.queued.count == 2 })

        // 一つ目を編集中に実行が始まり、保存できずに終える → 書きかけが取っておかれる。
        model.draft.prompt = "書きかけ"
        model.beginEditing(jobs[0].id)
        model.draft.prompt = "一つ目の書き直し"
        var started = jobs[0]
        started.status = .running
        model.handle(.snapshot(QueueSnapshot(queued: [jobs[1]], running: [started], isPaused: false, concurrency: 3)))
        await model.saveEdit()
        #expect(model.canRestoreStashedDraft)

        // 取っておいた入力も、いまの入力もあるときに別のジョブを編集しようとすると断る（どちらも消さない）。
        model.beginEditing(jobs[1].id)
        #expect(!model.isEditing)
        #expect(model.draft.prompt == "一つ目の書き直し")
        #expect(model.inputMessage?.contains("前に取っておいた入力が残っています") == true)
        #expect(model.canRestoreStashedDraft)
    }

    @Test func addingCommitsPendingSettingDrafts() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.outputDirectoryDraft = "~/Pictures/NewAssets"
        #expect(model.hasPendingSettingDrafts)
        model.draft.prompt = "猫"
        await model.addSingle()
        #expect(model.settings.outputDirectory == "~/Pictures/NewAssets")
        #expect(!model.hasPendingSettingDrafts)
        #expect(await uitWaitUntil {
            h.queue.current.settings.last?.outputDirectory == "~/Pictures/NewAssets"
        })
    }

    @Test func quittingCommitsValidDraftsAndKeepsInvalidOnesOut() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let model = h.makeModel()
        model.outputDirectoryDraft = "~/Desktop/new-out"
        model.modelDraft = "bad model name"
        model.flushPendingSettingsEdits()
        let saved = SettingsStore(defaults: h.suite.defaults).load()
        #expect(saved.outputDirectory == "~/Desktop/new-out")
        #expect(saved.model.isEmpty, "空白入りのモデル名は反映しない")
        #expect(model.modelError != nil)
    }
}

@Suite("FinalFix 履歴")
struct FinalFixHistoryTests {
    @Test func foreignRunJSONIsNotListedSoNoUndeletableRowsAppear() throws {
        let tmp = try QTempDir()
        defer { tmp.remove() }
        let out = tmp.sub("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // このアプリが書いた記録。
        let ours = try qWriteRunFolder(in: out, name: "20261025-010000-ours", record: qFinishedRecord(slug: "ours", startedAt: Date()), images: ["ours-01.png"])
        // 手で作った run.json（id だけ）。
        let foreign = out.appendingPathComponent("someone-else", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data(#"{"id":"\#(UUID().uuidString)"}"#.utf8).write(to: foreign.appendingPathComponent("run.json"))
        try Data("keep".utf8).write(to: foreign.appendingPathComponent("prompt.txt"))

        let store = HistoryStore(indexURL: tmp.url.appendingPathComponent("history.json"))
        let records = store.loadAll(outputDirectory: out)
        #expect(records.map(\.slug) == ["ours"])
        #expect(records.first.map { URL(fileURLWithPath: $0.outputDir).lastPathComponent } == ours.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: foreign.appendingPathComponent("prompt.txt").path), "触らない")
    }
}
