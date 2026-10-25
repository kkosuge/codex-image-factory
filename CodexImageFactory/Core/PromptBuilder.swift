import Foundation

/// Codex に渡すプロンプトの組み立て。
///
/// 順序は要件定義どおり: 1. スタイルプリセット（空なら省略） 2. ユーザーのプロンプト本文 3. 固定の指示文。
enum PromptBuilder {
    /// 期待するファイル名。例: `kina-mascot-01.png`, `kina-mascot-02.png`
    static func expectedFileNames(slug: String, count: Int) -> [String] {
        let n = max(1, count)
        return (1...n).map { String(format: "%@-%02d.png", slug, $0) }
    }

    /// 固定指示文のテンプレートを埋める。
    ///
    /// - `{count}`: 枚数
    /// - `{filenames}`: `` `a-01.png`、`a-02.png` ``
    /// - `{slug}`: スラッグ
    /// - `{size}`: 「正方形（1:1）」など
    /// - `{background}`: 「背景は透明（…）。」など。指定なしなら空
    static func instruction(
        template: String,
        slug: String,
        count: Int,
        aspect: ImageAspect,
        background: ImageBackground
    ) -> String {
        let names = expectedFileNames(slug: slug, count: count)
            .map { "`\($0)`" }
            .joined(separator: "、")
        return template
            .replacingOccurrences(of: "{count}", with: String(max(1, count)))
            .replacingOccurrences(of: "{filenames}", with: names)
            .replacingOccurrences(of: "{slug}", with: slug)
            .replacingOccurrences(of: "{size}", with: aspect.promptPhrase)
            .replacingOccurrences(of: "{background}", with: background.promptSentence)
    }

    /// 空でない部分を空行区切りで連結する。
    static func build(preset: String, prompt: String, instruction: String) -> String {
        [preset, prompt, instruction]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// ジョブと設定から最終プロンプトを作る。
    static func fullPrompt(for job: JobRecord, template: String) -> String {
        let inst = instruction(
            template: template,
            slug: job.slug,
            count: job.count,
            aspect: job.aspect,
            background: job.background
        )
        return build(preset: job.preset, prompt: job.prompt, instruction: inst)
    }

    /// 「まとめて追加」用。空行（空白だけの行を含む）で区切って、空でないプロンプトを返す。
    static func splitBatch(_ text: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    blocks.append(current.joined(separator: "\n"))
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            blocks.append(current.joined(separator: "\n"))
        }
        return blocks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
