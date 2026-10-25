import Foundation

/// 画面に出す文字列の組み立て。状態はすべて文字で表す。
enum UIDisplayFormat {
    /// 履歴の 1 行。例: 「完了 · kina-mascot · 1:02 · 2 枚 · 10/24 15:30」
    static func historyLine(_ record: JobRecord, calendar: Calendar = .current) -> String {
        let elapsed = ElapsedFormatter.string(from: record.elapsed(now: record.finishedAt ?? record.startedAt ?? record.createdAt))
        let date = shortDate(record.startedAt ?? record.createdAt, calendar: calendar)
        return "\(record.status.label) · \(record.slug) · \(elapsed) · \(record.images.count) 枚 · \(date)"
    }

    /// 「10/24 15:30」
    static func shortDate(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        return String(format: "%d/%d %02d:%02d", c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// 「2026/10/24 15:30:12」。nil なら「—」。
    static func fullDate(_ date: Date?, calendar: Calendar = .current) -> String {
        guard let date else { return "—" }
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d/%02d/%02d %02d:%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }

    /// 行の位置（0 始まりの番号から「3 番目」）。
    static func ordinal(_ index: Int) -> String {
        "\(index + 1) 番目"
    }

    /// キューの行の位置。実行中の行から順に、ペイン全体で通し番号にする。例: 「2 番目」
    static func queuePosition(_ index: Int) -> String {
        ordinal(index)
    }

    /// 履歴の行の位置（新しい順）。キューの行と見分けるため「履歴」を付ける。例: 「履歴 3 番目」
    static func historyPosition(_ index: Int) -> String {
        "履歴 \(ordinal(index))"
    }

    /// 行の操作ボタンの AX ラベル。スラッグが同じ行があっても見分けられるよう位置を入れる。
    /// 例: 「削除: 2 番目 kina-mascot」「再試行: 履歴 3 番目 kina-mascot」
    static func rowControlLabel(_ action: String, position: String, slug: String) -> String {
        "\(action): \(position) \(slug)"
    }

    /// 空でない最初の行。
    static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
}
