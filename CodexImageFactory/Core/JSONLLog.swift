import Foundation

/// stdout の JSONL を、ログペイン向けの 1 行に整える。
///
/// JSONL のスキーマはバージョンで変わるので、知っているキーがあれば使い、なければ JSON を短くして出す。
/// ここでの結果は表示用で、必須処理（成否判定など）には使わない。
enum JSONLLog {
    static let maxTextLength = 600
    static let maxOutputLength = 300

    static func format(line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
            return line
        }
        let type = (obj["type"] as? String) ?? "event"

        if let item = obj["item"] as? [String: Any] {
            let itemType = (item["type"] as? String) ?? "item"
            let header = "[\(type) · \(itemType)]"
            if let command = item["command"] as? String {
                var s = "\(header) $ \(truncate(command, maxTextLength))"
                if let code = item["exit_code"] as? Int {
                    s += String(localized: "（終了コード \(code)）", comment: "ログペイン: 実行したコマンドの終了コード")
                }
                if let output = item["aggregated_output"] as? String, !output.isEmpty, type != "item.started" {
                    s += "\n    " + truncate(output.trimmingCharacters(in: .whitespacesAndNewlines), maxOutputLength)
                        .replacingOccurrences(of: "\n", with: "\n    ")
                }
                return s
            }
            if let text = (item["text"] as? String) ?? (item["message"] as? String) {
                return "\(header) \(truncate(text.trimmingCharacters(in: .whitespacesAndNewlines), maxTextLength))"
            }
            return "\(header) \(compact(item))"
        }

        if let threadId = obj["thread_id"] as? String {
            return "[\(type)] thread_id=\(threadId)"
        }
        if let usage = obj["usage"] as? [String: Any] {
            let input = usage["input_tokens"].map { "\($0)" } ?? "?"
            let output = usage["output_tokens"].map { "\($0)" } ?? "?"
            return String(localized: "[\(type)] 入力トークン \(input) / 出力トークン \(output)", comment: "ログペイン: 最初の %@ は JSONL のイベント種別（turn.completed など）、残りはトークン数")
        }
        if let message = obj["message"] as? String {
            return "[\(type)] \(truncate(message, maxTextLength))"
        }
        if let error = obj["error"] as? [String: Any], let message = error["message"] as? String {
            return "[\(type)] \(truncate(message, maxTextLength))"
        }
        var rest = obj
        rest.removeValue(forKey: "type")
        return rest.isEmpty ? "[\(type)]" : "[\(type)] \(compact(rest))"
    }

    /// stdout の JSONL からエラーメッセージ（`error` / `turn.failed`）を取り出す。失敗時の要約に使う。
    static func errorMessage(line: String) -> String? {
        guard line.contains("error") || line.contains("failed"),
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = obj["type"] as? String else {
            return nil
        }
        switch type {
        case "error":
            return obj["message"] as? String
        case "turn.failed":
            return ((obj["error"] as? [String: Any])?["message"] as? String) ?? "turn.failed"
        default:
            return nil
        }
    }

    static func truncate(_ s: String, _ limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + String(localized: "…（\(s.count - limit) 文字省略）", comment: "長い文字列を切ったときに末尾に付ける。数字は省略した文字数")
    }

    private static func compact(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return truncate(s, maxTextLength)
    }
}
