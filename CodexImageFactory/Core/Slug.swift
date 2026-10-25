import Foundation

/// 出力ファイル名・フォルダ名に使うスラッグ。
enum Slug {
    static let maxLength = 60

    /// パスに使えない文字や空白を `-` に置き換え、連続する `-` をまとめ、前後の `-` `.` を落とす。
    /// 日本語などの文字はそのまま残す（macOS のファイル名として問題ないため）。
    static func sanitize(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|`$'")
            .union(.whitespacesAndNewlines)
            .union(.controlCharacters)
        var out = ""
        var lastWasDash = false
        for scalar in raw.unicodeScalars {
            if forbidden.contains(scalar) || scalar == "-" {
                if !lastWasDash && !out.isEmpty {
                    out.append("-")
                }
                lastWasDash = true
            } else {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if trimmed.count > maxLength {
            return String(trimmed.prefix(maxLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        }
        return trimmed
    }

    /// `YYYYMMDD-HHmmss`（端末のタイムゾーン）。
    static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }

    /// 入力をサニタイズし、空ならタイムスタンプを使う。
    static func effective(_ raw: String, date: Date, timeZone: TimeZone = .current) -> String {
        let s = sanitize(raw)
        return s.isEmpty ? timestamp(date, timeZone: timeZone) : s
    }

    /// 実行フォルダ名 `<YYYYMMDD-HHmmss>-<スラッグ>`。
    /// スラッグ自体がタイムスタンプ形式のとき（スラッグ未入力のジョブ）は重複を避けて開始時刻だけにする。
    static func folderName(slug: String, startedAt: Date, timeZone: TimeZone = .current) -> String {
        let ts = timestamp(startedAt, timeZone: timeZone)
        if slug.isEmpty || slug == ts || isTimestamp(slug) {
            return ts
        }
        return "\(ts)-\(slug)"
    }

    /// `YYYYMMDD-HHmmss` 形式かどうか。
    static func isTimestamp(_ s: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        guard scalars.count == 15, scalars[8] == "-" else { return false }
        for (i, u) in scalars.enumerated() where i != 8 {
            guard CharacterSet.decimalDigits.contains(u) else { return false }
        }
        return true
    }
}
