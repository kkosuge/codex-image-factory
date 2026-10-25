import Foundation

/// 入力欄の内容。
struct JobDraft: Sendable, Equatable {
    var prompt: String = ""
    var slug: String = ""
    var count: Int = ImageCount.default
    var aspect: ImageAspect = .square
    var background: ImageBackground = .transparent
    var referenceImages: [String] = []

    /// プロンプトが空でなければ追加できる。
    var canSubmit: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 「まとめて追加」で何件になるか。
    var batchCount: Int {
        PromptBuilder.splitBatch(prompt).count
    }
}

/// 入力内容からジョブを作る。
enum JobFactory {
    /// 「生成」: 入力内容で 1 件。プロンプトが空なら nil。
    static func single(from draft: JobDraft, preset: String, template: String, now: Date) -> JobRecord? {
        let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        return make(prompt: prompt, slug: Slug.effective(draft.slug, date: now), draft: draft, preset: preset, template: template, now: now)
    }

    /// 「まとめて追加」: 空行区切りのプロンプトを 1 件ずつ。枚数・サイズ・背景・プリセット・参照画像は共通。
    /// スラッグを入力していれば `<スラッグ>-1`, `<スラッグ>-2`, … とする（1 件だけならそのまま）。
    /// スラッグが空なら、行を見分けられるようにタイムスタンプを 1 秒ずつずらす。
    static func batch(from draft: JobDraft, preset: String, template: String, now: Date) -> [JobRecord] {
        let prompts = PromptBuilder.splitBatch(draft.prompt)
        let base = Slug.sanitize(draft.slug)
        return prompts.enumerated().map { index, prompt in
            let slug: String
            if base.isEmpty {
                slug = Slug.timestamp(now.addingTimeInterval(Double(index)))
            } else if prompts.count == 1 {
                slug = base
            } else {
                slug = "\(base)-\(index + 1)"
            }
            // 作成時刻をわずかにずらし、並び順が安定するようにする。
            let created = now.addingTimeInterval(Double(index) * 0.001)
            return make(prompt: prompt, slug: slug, draft: draft, preset: preset, template: template, now: created)
        }
    }

    /// 待機中ジョブの編集。プリセットは追加時点のスナップショットを保つ。
    static func apply(_ draft: JobDraft, to job: JobRecord, template: String) -> JobRecord? {
        let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        var j = job
        j.prompt = prompt
        j.slug = Slug.effective(draft.slug, date: job.createdAt)
        j.count = ImageCount.choices.contains(draft.count) ? draft.count : ImageCount.default
        j.aspect = draft.aspect
        j.background = draft.background
        j.referenceImages = Array(draft.referenceImages.prefix(ReferenceImageLimit.max))
        j.fullPrompt = PromptBuilder.fullPrompt(for: j, template: template)
        return j
    }

    /// 履歴やキューのジョブから入力欄の内容を作る（「このプロンプトを再利用」「編集」）。
    static func draft(from job: JobRecord) -> JobDraft {
        JobDraft(
            prompt: job.prompt,
            slug: Slug.isTimestamp(job.slug) ? "" : job.slug,
            count: ImageCount.choices.contains(job.count) ? job.count : ImageCount.default,
            aspect: job.aspect,
            background: job.background,
            referenceImages: Array(job.referenceImages.prefix(ReferenceImageLimit.max))
        )
    }

    private static func make(prompt: String, slug: String, draft: JobDraft, preset: String, template: String, now: Date) -> JobRecord {
        var job = JobRecord(
            createdAt: now,
            slug: slug,
            prompt: prompt,
            preset: preset.trimmingCharacters(in: .whitespacesAndNewlines),
            count: ImageCount.choices.contains(draft.count) ? draft.count : ImageCount.default,
            aspect: draft.aspect,
            background: draft.background,
            referenceImages: Array(draft.referenceImages.prefix(ReferenceImageLimit.max))
        )
        // 追加時点の見込み。実行開始時に最新の固定指示文で組み立て直す。
        job.fullPrompt = PromptBuilder.fullPrompt(for: job, template: template)
        return job
    }
}
