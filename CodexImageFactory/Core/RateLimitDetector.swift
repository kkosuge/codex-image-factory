import Foundation

/// レート制限らしきエラーの検出。
///
/// 見るのは stderr と、stdout のうち `type` が `error` / `turn.failed` の行だけ。
/// コマンド出力や Codex の返答本文には「rate limit」などの文字が普通に混じるので見ない。
enum RateLimitDetector {
    private static let phrases = [
        "rate limit", "rate_limit", "ratelimit", "rate-limit",
        "too many requests", "usage limit", "usage_limit",
        "quota exceeded", "insufficient_quota",
    ]

    static func isRateLimited(stream: CodexStream, line: String) -> Bool {
        switch stream {
        case .stderr:
            return matches(line)
        case .stdout:
            guard let message = JSONLLog.errorMessage(line: line) else { return false }
            return matches(message)
        }
    }

    static func matches(_ text: String) -> Bool {
        let lower = text.lowercased()
        if phrases.contains(where: lower.contains) {
            return true
        }
        return containsStatus429(lower)
    }

    /// 「429」が単独の語として出ているか（`status":429`, `429 Too Many`, `HTTP 429` など）。
    /// UUID やファイル名の一部（`f429e`, `-429-`, `1.429`）は除く。
    private static func containsStatus429(_ s: String) -> Bool {
        func isWordChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "-" || c == "_" || c == "."
        }
        var searchStart = s.startIndex
        while let r = s.range(of: "429", range: searchStart..<s.endIndex) {
            let before: Character = r.lowerBound > s.startIndex ? s[s.index(before: r.lowerBound)] : " "
            let after: Character = r.upperBound < s.endIndex ? s[r.upperBound] : " "
            if !isWordChar(before) && !isWordChar(after) {
                return true
            }
            searchStart = r.upperBound
        }
        return false
    }
}
