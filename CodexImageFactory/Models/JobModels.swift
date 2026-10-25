import Foundation

/// ジョブの状態。
enum JobStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case done
    case failed
    case cancelled

    /// 画面に出す日本語ラベル。色やアイコンに頼らず、文字で状態を示すために使う。
    var label: String {
        switch self {
        case .queued: String(localized: "待機中", comment: "ジョブの状態")
        case .running: String(localized: "実行中", comment: "ジョブの状態")
        case .done: String(localized: "完了", comment: "ジョブの状態")
        case .failed: String(localized: "失敗", comment: "ジョブの状態")
        case .cancelled: String(localized: "job.status.cancelled", defaultValue: "中止", comment: "ジョブの状態（中止された）。ボタンの「中止」とは別のキーにしている")
        }
    }

    var isFinished: Bool {
        switch self {
        case .done, .failed, .cancelled: true
        case .queued, .running: false
        }
    }
}

/// 画像の縦横比。
enum ImageAspect: String, Codable, Sendable, CaseIterable, Identifiable {
    case square
    case landscape
    case portrait

    var id: String { rawValue }

    var label: String {
        switch self {
        case .square: String(localized: "正方形", comment: "画像の縦横比のラベル")
        case .landscape: String(localized: "横長", comment: "画像の縦横比のラベル")
        case .portrait: String(localized: "縦長", comment: "画像の縦横比のラベル")
        }
    }

    /// 固定指示文の `{size}` に入る文言。
    var promptPhrase: String {
        switch self {
        case .square: String(localized: "正方形（1:1）", comment: "Codex（AI モデル）に送る指示文の {size} に入る文言")
        case .landscape: String(localized: "横長（3:2）", comment: "Codex（AI モデル）に送る指示文の {size} に入る文言")
        case .portrait: String(localized: "縦長（2:3）", comment: "Codex（AI モデル）に送る指示文の {size} に入る文言")
        }
    }
}

/// 画像の背景。
enum ImageBackground: String, Codable, Sendable, CaseIterable, Identifiable {
    case transparent
    case white
    case unspecified

    var id: String { rawValue }

    var label: String {
        switch self {
        case .transparent: String(localized: "透明", comment: "画像の背景のラベル")
        case .white: String(localized: "白", comment: "画像の背景のラベル")
        case .unspecified: String(localized: "指定なし", comment: "画像の背景のラベル")
        }
    }

    /// 固定指示文の `{background}` に入る文言。指定なしなら空文字。
    var promptSentence: String {
        switch self {
        case .transparent: String(localized: "背景は透明（アルファチャンネル付きの PNG）。", comment: "Codex（AI モデル）に送る指示文の {background} に入る文")
        case .white: String(localized: "背景は白。", comment: "Codex（AI モデル）に送る指示文の {background} に入る文")
        case .unspecified: ""
        }
    }
}

/// 生成枚数の選択肢。
enum ImageCount {
    static let choices: [Int] = [1, 2, 4]
    static let `default` = 1
}

/// 参照画像の上限枚数。
enum ReferenceImageLimit {
    static let max = 4
}

/// ジョブ 1 件。実行 1 回の記録（run.json）も同じ型で表す。
///
/// フィールドは要件定義の「データモデル」の表に合わせている。stdout / stderr の生データは
/// run.json には入れず、同じフォルダの `stdout.jsonl` / `stderr.log` に置く。
struct JobRecord: Codable, Sendable, Identifiable, Equatable, Hashable {
    var id: UUID
    var status: JobStatus
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    /// ファイル名に使う短い名前（サニタイズ済み。空にはしない）。
    var slug: String
    /// ユーザー入力の本文。
    var prompt: String
    /// スタイルプリセット（追加時点のスナップショット）。
    var preset: String
    /// Codex に渡した最終プロンプト。実行開始時に組み立てる。
    var fullPrompt: String
    var count: Int
    var aspect: ImageAspect
    var background: ImageBackground
    /// 参照画像の絶対パス。
    var referenceImages: [String]
    /// 実行したコマンドと引数の配列（先頭は codex の絶対パス）。
    var command: [String]
    /// シェルでそのまま打てる 1 行（クォート済み）。
    var commandLine: String
    var exitCode: Int?
    /// ジョブのフォルダ（絶対パス）。実行開始前は空文字。
    var outputDir: String
    /// 生成画像の絶対パス。
    var images: [String]
    /// Codex の最終メッセージ（last-message.md の中身）。
    var lastMessage: String
    /// 失敗時の要約（stderr 末尾など）。
    var errorSummary: String?
    /// Codex のスレッド ID（JSONL の thread.started から取る）。画像の予備の取り出しに使う。
    var codexThreadId: String?

    init(
        id: UUID = UUID(),
        status: JobStatus = .queued,
        createdAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        slug: String,
        prompt: String,
        preset: String,
        fullPrompt: String = "",
        count: Int,
        aspect: ImageAspect,
        background: ImageBackground,
        referenceImages: [String] = [],
        command: [String] = [],
        commandLine: String = "",
        exitCode: Int? = nil,
        outputDir: String = "",
        images: [String] = [],
        lastMessage: String = "",
        errorSummary: String? = nil,
        codexThreadId: String? = nil
    ) {
        self.id = id
        self.status = status
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.slug = slug
        self.prompt = prompt
        self.preset = preset
        self.fullPrompt = fullPrompt
        self.count = count
        self.aspect = aspect
        self.background = background
        self.referenceImages = referenceImages
        self.command = command
        self.commandLine = commandLine
        self.exitCode = exitCode
        self.outputDir = outputDir
        self.images = images
        self.lastMessage = lastMessage
        self.errorSummary = errorSummary
        self.codexThreadId = codexThreadId
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, createdAt, startedAt, finishedAt, slug, prompt, preset, fullPrompt
        case count, aspect, background, referenceImages, command, commandLine, exitCode
        case outputDir, images, lastMessage, errorSummary, codexThreadId
    }

    /// run.json は手で編集されたり古い版のアプリが書いたりするので、id 以外は欠けていても読めるようにする。
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        status = (try? c.decodeIfPresent(JobStatus.self, forKey: .status)) ?? .failed
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        startedAt = try? c.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try? c.decodeIfPresent(Date.self, forKey: .finishedAt)
        slug = (try? c.decodeIfPresent(String.self, forKey: .slug)) ?? ""
        prompt = (try? c.decodeIfPresent(String.self, forKey: .prompt)) ?? ""
        preset = (try? c.decodeIfPresent(String.self, forKey: .preset)) ?? ""
        fullPrompt = (try? c.decodeIfPresent(String.self, forKey: .fullPrompt)) ?? ""
        count = (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? ImageCount.default
        aspect = (try? c.decodeIfPresent(ImageAspect.self, forKey: .aspect)) ?? .square
        background = (try? c.decodeIfPresent(ImageBackground.self, forKey: .background)) ?? .unspecified
        referenceImages = (try? c.decodeIfPresent([String].self, forKey: .referenceImages)) ?? []
        command = (try? c.decodeIfPresent([String].self, forKey: .command)) ?? []
        commandLine = (try? c.decodeIfPresent(String.self, forKey: .commandLine)) ?? ""
        exitCode = try? c.decodeIfPresent(Int.self, forKey: .exitCode)
        outputDir = (try? c.decodeIfPresent(String.self, forKey: .outputDir)) ?? ""
        images = (try? c.decodeIfPresent([String].self, forKey: .images)) ?? []
        lastMessage = (try? c.decodeIfPresent(String.self, forKey: .lastMessage)) ?? ""
        errorSummary = try? c.decodeIfPresent(String.self, forKey: .errorSummary)
        codexThreadId = try? c.decodeIfPresent(String.self, forKey: .codexThreadId)
    }

    /// 再試行用に、入力内容だけを引き継いだ新しい待機中ジョブを作る。
    /// fullPrompt は表示用の見込みとして引き継ぐ（実行開始時に最新の固定指示文で組み立て直す）。
    func makeRetry(now: Date) -> JobRecord {
        JobRecord(
            createdAt: now,
            slug: slug,
            prompt: prompt,
            preset: preset,
            fullPrompt: fullPrompt,
            count: count,
            aspect: aspect,
            background: background,
            referenceImages: referenceImages
        )
    }

    /// キュー一覧に出す 1 行。例: 「待機中 · kina-mascot · 0:42」
    func queueLine(now: Date) -> String {
        "\(status.label) · \(slug) · \(ElapsedFormatter.string(from: elapsed(now: now)))"
    }

    /// 経過時間。待機中は追加からの時間、実行中は開始からの時間、終了後は実行にかかった時間。
    func elapsed(now: Date) -> TimeInterval {
        switch status {
        case .queued:
            return max(0, now.timeIntervalSince(createdAt))
        case .running:
            return max(0, now.timeIntervalSince(startedAt ?? now))
        case .done, .failed, .cancelled:
            guard let startedAt else { return 0 }
            return max(0, (finishedAt ?? startedAt).timeIntervalSince(startedAt))
        }
    }
}

/// 経過秒数を「0:42」「12:05」「1:02:03」の形にする。
enum ElapsedFormatter {
    static func string(from interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
