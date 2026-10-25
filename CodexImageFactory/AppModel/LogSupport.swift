import Foundation
import Observation

/// ログペインの表示形式。
enum LogDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case formatted
    case raw

    var id: String { rawValue }

    var label: String {
        switch self {
        case .formatted: String(localized: "整形", comment: "ログ表示形式: 整形したログ")
        case .raw: String(localized: "生データ", comment: "ログ表示形式: 加工していない生のログ")
        }
    }
}

/// 実行中ジョブのログ（stdout / stderr を届いた順に）。整形済みと生データを両方持つ。
@MainActor
@Observable
final class LiveJobLog {
    /// 覚えておく行数の目安。これを少し超えたら古い行から捨てる。
    static let maxLines = 5000
    private static let trimSlack = 500

    private(set) var raw: [String] = []
    private(set) var formatted: [String] = []
    /// 古い順に捨てた行数。
    private(set) var droppedCount = 0

    func append(stream: CodexStream, text: String) {
        switch stream {
        case .stdout:
            raw.append(text)
            formatted.append(JSONLLog.format(line: text))
        case .stderr:
            let line = "[stderr] " + text
            raw.append(line)
            formatted.append(line)
        }
        // 毎行ずらすと重いので、少し溜めてからまとめて捨てる。
        if raw.count > Self.maxLines + Self.trimSlack {
            let overflow = raw.count - Self.maxLines
            raw.removeFirst(overflow)
            formatted.removeFirst(overflow)
            droppedCount += overflow
        }
    }

    func display(_ mode: LogDisplayMode) -> LogDisplayText {
        LogDisplayText.make(lines: mode == .raw ? raw : formatted, alreadyDropped: droppedCount)
    }
}

/// ログペインに出す文字列。長すぎるログは末尾だけにする。
struct LogDisplayText: Equatable, Sendable {
    static let displayLimit = 3000

    var text: String
    var shownLines: Int
    var omittedLines: Int

    /// 省略したときの注記。
    var note: String? {
        guard omittedLines > 0 else { return nil }
        return String(localized: "古い \(omittedLines) 行は省略し、最後の \(shownLines) 行を表示しています。")
    }

    static func make(lines: [String], alreadyDropped: Int = 0, limit: Int = displayLimit) -> LogDisplayText {
        let shown = lines.suffix(max(0, limit))
        return LogDisplayText(
            text: shown.joined(separator: "\n"),
            shownLines: shown.count,
            omittedLines: alreadyDropped + lines.count - shown.count
        )
    }
}

/// 終わったジョブのログ（stdout.jsonl と stderr.log から読んだもの）。
struct LoadedRunLog: Equatable, Sendable {
    var raw: [String]
    var formatted: [String]
    /// 読み込み時に省略した古い行数。
    var omittedLines: Int

    func display(_ mode: LogDisplayMode) -> LogDisplayText {
        LogDisplayText.make(lines: mode == .raw ? raw : formatted, alreadyDropped: omittedLines)
    }

    /// stdout の後ろに stderr（`[stderr] ` 付き）を並べ、末尾 `limit` 行だけ残す。整形も残す分だけする。
    static func make(stdout: String, stderr: String, limit: Int = LogDisplayText.displayLimit) -> LoadedRunLog {
        let out = splitLines(stdout)
        let err = splitLines(stderr).map { "[stderr] " + $0 }
        let keepErr = Array(err.suffix(max(0, limit)))
        let keepOut = Array(out.suffix(max(0, limit - keepErr.count)))
        return LoadedRunLog(
            raw: keepOut + keepErr,
            formatted: keepOut.map { JSONLLog.format(line: $0) } + keepErr,
            omittedLines: out.count + err.count - keepOut.count - keepErr.count
        )
    }

    /// 改行で分ける（`\r\n` は Swift では 1 文字なので isNewline で見る）。末尾の改行で空行を作らない。
    static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }
}
