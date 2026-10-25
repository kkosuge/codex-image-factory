import Foundation

/// 参照画像のパスの検証。テキスト欄・ドラッグ＆ドロップ・ファイル選択のどれからでも同じ規則で通す。
enum ReferenceImageValidator {
    static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]

    enum Failure: Error, Equatable, Sendable {
        case empty
        case notAbsolute(String)
        case notFound(String)
        case isDirectory(String)
        case notImage(String)
        case duplicate(String)
        case limitReached

        /// 入力欄の下に出す文言。
        var message: String {
            switch self {
            case .empty:
                "パスを入力してください。"
            case .notAbsolute(let path):
                "「/」か「~」から始まるパスを入力してください: \(path)"
            case .notFound(let path):
                "ファイルが見つかりません: \(path)"
            case .isDirectory(let path):
                "フォルダは追加できません。画像ファイルを指定してください: \(path)"
            case .notImage(let path):
                "画像ファイル（png / jpg / jpeg / webp）だけを追加できます: \(path)"
            case .duplicate(let path):
                "すでに追加されています: \(path)"
            case .limitReached:
                "参照画像は最大 \(ReferenceImageLimit.max) 枚までです。"
            }
        }
    }

    /// 入力を整えて検証し、追加してよい絶対パスを返す。
    static func validate(_ raw: String, existing: [String], home: URL) -> Result<String, Failure> {
        let cleaned = clean(raw)
        guard !cleaned.isEmpty else { return .failure(.empty) }
        let expanded = expandTilde(cleaned, home: home)
        guard expanded.hasPrefix("/") else { return .failure(.notAbsolute(cleaned)) }

        let fm = FileManager.default
        var path = standardize(expanded)
        var isDirectory: ObjCBool = false
        if !fm.fileExists(atPath: path, isDirectory: &isDirectory) {
            // ターミナルからコピーした「\ 」のようなエスケープを外して、もう一度探す。
            let unescaped = standardize(unescapeShell(expanded))
            guard unescaped != path, fm.fileExists(atPath: unescaped, isDirectory: &isDirectory) else {
                return .failure(.notFound(path))
            }
            path = unescaped
        }
        if isDirectory.boolValue {
            return .failure(.isDirectory(path))
        }
        guard allowedExtensions.contains((path as NSString).pathExtension.lowercased()) else {
            return .failure(.notImage(path))
        }
        if existing.contains(where: { standardize($0) == path }) {
            return .failure(.duplicate(path))
        }
        guard existing.count < ReferenceImageLimit.max else {
            return .failure(.limitReached)
        }
        return .success(path)
    }

    /// 前後の空白・囲みの引用符・`file://` を外す。
    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("'", "'"), ("「", "」")] where s.count >= 2 && s.hasPrefix(open) && s.hasSuffix(close) {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if s.hasPrefix("file://"), let url = URL(string: s), url.isFileURL {
            s = url.path
        }
        return s
    }

    /// `~` と `~/...` を `home` に展開する。`~user` は Foundation に任せる。
    static func expandTilde(_ path: String, home: URL) -> String {
        if path == "~" {
            return home.path
        }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2))).path
        }
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        return path
    }

    static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// `\ ` `\(` のようなバックスラッシュのエスケープを外す。
    private static func unescapeShell(_ path: String) -> String {
        var out = ""
        var escaping = false
        for c in path {
            if escaping {
                out.append(c)
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                out.append(c)
            }
        }
        return out
    }
}
