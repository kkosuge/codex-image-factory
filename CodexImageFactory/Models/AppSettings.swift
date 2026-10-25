import Foundation

/// Codex に渡す推論の強さ（`-c model_reasoning_effort=...`）。既定なら何も渡さない。
enum ReasoningEffort: String, Codable, Sendable, CaseIterable, Identifiable {
    case `default`
    case low
    case medium
    case high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .default: "既定"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        }
    }
}

/// アプリ設定。UserDefaults に保存する（保存処理は SettingsStore）。
struct AppSettings: Codable, Sendable, Equatable {
    /// 出力ディレクトリ。`~` を含んでよい。
    var outputDirectory: String
    /// codex の絶対パス。空なら起動時にログインシェルで解決した値を使う。
    var codexPath: String
    /// 同時に走らせる codex exec の数（1〜8）。
    var concurrency: Int
    /// 1 ジョブのタイムアウト秒数。
    var timeoutSeconds: Int
    /// プロンプトの先頭に付ける定型文。
    var stylePreset: String
    /// 固定の指示文。`{count}` `{filenames}` `{slug}` `{size}` `{background}` を置き換える。
    var instructionTemplate: String
    /// `-m` に渡すモデル名。空なら渡さない。
    var model: String
    var reasoningEffort: ReasoningEffort
    /// `--ephemeral` を付けるか。
    var useEphemeral: Bool

    static let concurrencyRange = 1...8
    static let minimumTimeoutSeconds = 30

    static let defaultOutputDirectory = "~/Pictures/CodexImages"

    static let defaultInstructionTemplate =
        "画像生成ツールを使って {count} 枚生成し、PNG としてカレントディレクトリに {filenames} の名前で保存すること。"
        + "サイズは{size}。{background}"
        + "ファイルを保存したら、最後に保存したファイル名を 1 行 1 ファイルで列挙すること。"
        + "コードの変更やその他のファイル作成はしないこと。"

    static let defaults = AppSettings(
        outputDirectory: defaultOutputDirectory,
        codexPath: "",
        concurrency: 3,
        timeoutSeconds: 600,
        stylePreset: "",
        instructionTemplate: defaultInstructionTemplate,
        model: "",
        reasoningEffort: .default,
        useEphemeral: false
    )

    /// 範囲外の値を丸めた設定を返す。
    func normalized() -> AppSettings {
        var s = self
        s.concurrency = min(max(s.concurrency, Self.concurrencyRange.lowerBound), Self.concurrencyRange.upperBound)
        s.timeoutSeconds = max(s.timeoutSeconds, Self.minimumTimeoutSeconds)
        if s.instructionTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s.instructionTemplate = Self.defaultInstructionTemplate
        }
        if s.outputDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s.outputDirectory = Self.defaultOutputDirectory
        }
        return s
    }

    /// `~` を展開した出力ディレクトリ。
    var outputDirectoryURL: URL {
        URL(fileURLWithPath: PathUtil.expandTilde(outputDirectory.trimmingCharacters(in: .whitespacesAndNewlines)), isDirectory: true)
            .standardizedFileURL
    }
}

enum PathUtil {
    /// `~` と `~/...` をホームディレクトリに展開する。
    static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// ユーザーのホームディレクトリ。サンドボックスなしの前提で NSHomeDirectory を使う。
    static var homeDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// Codex のホーム（`$CODEX_HOME` があればそれ、なければ `~/.codex`）。
    static func codexHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: expandTilde(custom), isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    /// `~/Library/Application Support/CodexImageFactory/`
    static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("CodexImageFactory", isDirectory: true)
    }
}
