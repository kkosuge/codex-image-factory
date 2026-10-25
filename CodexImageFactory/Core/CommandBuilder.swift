import Foundation

/// `codex exec` のコマンド配列を作る。
///
/// ```
/// codex exec -C <dir> -s workspace-write --skip-git-repo-check --json -o <dir>/last-message.md
///   [-m <model>] [-c model_reasoning_effort="..."] [--ephemeral] [-i <ref> ...] -- "<prompt>"
/// ```
///
/// `-i` は複数値を取るオプションなので、プロンプトの前に `--` を置いて取り違えを防ぐ。
enum CommandBuilder {
    static let lastMessageFileName = "last-message.md"

    struct Options: Sendable, Equatable {
        var codexPath: String
        var workingDirectory: String
        var prompt: String
        var referenceImages: [String] = []
        var model: String = ""
        var reasoningEffort: ReasoningEffort = .default
        var ephemeral: Bool = false
    }

    /// 実行ファイルの後ろに付ける引数。
    static func arguments(_ o: Options) -> [String] {
        var args: [String] = [
            "exec",
            "-C", o.workingDirectory,
            "-s", "workspace-write",
            "--skip-git-repo-check",
            "--json",
            "-o", (o.workingDirectory as NSString).appendingPathComponent(lastMessageFileName),
        ]
        let model = o.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty {
            args += ["-m", model]
        }
        if o.reasoningEffort != .default {
            args += ["-c", "model_reasoning_effort=\"\(o.reasoningEffort.rawValue)\""]
        }
        if o.ephemeral {
            args.append("--ephemeral")
        }
        for ref in o.referenceImages {
            args += ["-i", ref]
        }
        args += ["--", o.prompt]
        return args
    }

    /// `[codexPath] + arguments`
    static func command(_ o: Options) -> [String] {
        [o.codexPath] + arguments(o)
    }

    /// シェルにそのまま貼れる 1 行。
    static func commandLine(_ o: Options) -> String {
        ShellQuote.join(command(o))
    }
}
