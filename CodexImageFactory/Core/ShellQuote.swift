import Foundation

/// POSIX シェル（zsh / bash）向けのクォート。
enum ShellQuote {
    /// クォート不要とみなす文字。これ以外を含む引数はシングルクォートで囲む。
    private static let safe = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_"
    )

    /// 1 つの引数をクォートする。
    ///
    /// - 普通はシングルクォートで囲む。中では展開が起きないので `'` だけを `'\''` に置き換えればよい。
    /// - 改行・タブなどの制御文字を含むときは、zsh / bash の `$'...'` で 1 行に収める
    ///   （改行は `\n` に、`!` は履歴展開を避けて `\x21` にする）。
    static func quote(_ argument: String) -> String {
        if argument.isEmpty {
            return "''"
        }
        if argument.unicodeScalars.allSatisfy({ safe.contains($0) }) && !argument.hasPrefix("=") {
            return argument
        }
        if argument.unicodeScalars.contains(where: isASCIIControl) {
            return ansiCQuote(argument)
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isASCIIControl(_ u: Unicode.Scalar) -> Bool {
        u.value < 0x20 || u.value == 0x7F
    }

    /// `$'...'`（ANSI-C クォート）。
    private static func ansiCQuote(_ s: String) -> String {
        var out = "$'"
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "!": out += "\\x21"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if isASCIIControl(u) {
                    out += String(format: "\\x%02X", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "'"
    }

    /// 引数の配列を、シェルにそのまま貼れる 1 行にする（改行を含まない）。
    static func join(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }
}
