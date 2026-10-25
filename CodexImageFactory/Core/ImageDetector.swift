import Foundation

/// 生成画像の検出。主はファイルシステムの差分で、last-message の列挙・JSONL 内の画像データ・
/// `~/.codex/generated_images/<thread_id>/` は補助・予備として使う。
enum ImageDetector {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]

    static func isImageFile(_ name: String) -> Bool {
        imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// フォルダ内（サブフォルダを含む）の画像ファイルを、フォルダからの相対パスで返す。
    /// 隠しファイル・隠しフォルダは無視する。
    static func snapshot(directory: URL) -> Set<String> {
        let fm = FileManager.default
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = fm.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        var result = Set<String>()
        for case let url as URL in enumerator {
            guard isImageFile(url.lastPathComponent) else { continue }
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isFile else { continue }
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            if full.hasPrefix(basePath) {
                result.insert(String(full.dropFirst(basePath.count)))
            } else {
                result.insert(url.lastPathComponent)
            }
        }
        return result
    }

    /// 実行前のスナップショットにない画像を、相対パスの昇順で返す。
    static func newImages(before: Set<String>, directory: URL) -> [String] {
        snapshot(directory: directory).subtracting(before).sorted()
    }

    /// 期待するファイル名の順を優先し、残りは名前順に並べる。
    static func ordered(_ names: [String], expected: [String]) -> [String] {
        let set = Set(names)
        let head = expected.filter { set.contains($0) }
        let rest = names.filter { !head.contains($0) }.sorted()
        return head + rest
    }

    /// last-message.md の本文から、画像ファイル名らしい行を取り出す。
    /// 「- a.png」「1. a.png」「`a.png`」のような装飾は外す。
    static func fileNamesListed(in lastMessage: String) -> [String] {
        var names: [String] = []
        for rawLine in lastMessage.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            for prefix in ["- ", "* ", "• "] where line.hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count))
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty {
                let after = line[line.index(after: dot)...]
                if after.hasPrefix(" ") {
                    line = String(after).trimmingCharacters(in: .whitespaces)
                }
            }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "`*\"' "))
            if line.hasPrefix("./") {
                line = String(line.dropFirst(2))
            }
            guard !line.isEmpty, !line.contains(" "), isImageFile(line) else { continue }
            if !names.contains(line) {
                names.append(line)
            }
        }
        return names
    }

    /// JSONL の 1 行に、画像データ（data URL または長い base64）が入っていれば取り出す。
    /// Codex 0.164.0 では入らないことを確認済みだが、将来の版に備える。
    static func extractBase64Images(fromJSONLLine line: String) -> [(data: Data, fileExtension: String)] {
        guard line.count > 200,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
            return []
        }
        var found: [(Data, String)] = []
        var stack: [Any] = [obj]
        while let value = stack.popLast() {
            if let dict = value as? [String: Any] {
                stack.append(contentsOf: dict.values)
            } else if let array = value as? [Any] {
                stack.append(contentsOf: array)
            } else if let s = value as? String, s.count > 200 {
                if let decoded = decodeImageString(s) {
                    found.append(decoded)
                }
            }
        }
        return found
    }

    private static func decodeImageString(_ s: String) -> (Data, String)? {
        var payload = Substring(s)
        if s.hasPrefix("data:image/") {
            guard let comma = s.firstIndex(of: ","), s[..<comma].hasSuffix(";base64") else { return nil }
            payload = s[s.index(after: comma)...]
        } else if !(s.hasPrefix("iVBORw0KGgo") || s.hasPrefix("/9j/") || s.hasPrefix("UklGR")) {
            return nil
        }
        guard let data = Data(base64Encoded: String(payload), options: .ignoreUnknownCharacters),
              let ext = sniffExtension(data) else {
            return nil
        }
        return (data, ext)
    }

    /// 先頭バイトから画像形式を判定する。
    static func sniffExtension(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.count >= 12, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return "webp"
        }
        return nil
    }

    /// `thread.started` イベントからスレッド ID を取る。
    static func threadId(fromJSONLLine line: String) -> String? {
        guard line.contains("thread"),
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return nil
        }
        if let type = obj["type"] as? String, type == "thread.started" || type == "session.created" {
            return (obj["thread_id"] as? String) ?? (obj["session_id"] as? String)
        }
        return nil
    }

    /// `~/.codex/generated_images/<threadId>/` にある画像を、作成日時の古い順で返す。
    static func generatedImages(codexHome: URL, threadId: String, since: Date? = nil) -> [URL] {
        guard !threadId.isEmpty, !threadId.contains("/"), !threadId.contains("..") else { return [] }
        let dir = codexHome
            .appendingPathComponent("generated_images", isDirectory: true)
            .appendingPathComponent(threadId, isDirectory: true)
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let items: [(URL, Date)] = urls.compactMap { url in
            guard isImageFile(url.lastPathComponent) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile ?? false else { return nil }
            let date = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            if let since, date < since.addingTimeInterval(-5) { return nil }
            return (url, date)
        }
        return items
            .sorted { $0.1 == $1.1 ? $0.0.lastPathComponent < $1.0.lastPathComponent : $0.1 < $1.1 }
            .map(\.0)
    }
}
