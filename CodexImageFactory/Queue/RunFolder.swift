import Darwin
import Foundation
import Synchronization

/// ジョブ 1 件 = フォルダ 1 つ。フォルダの作成と、中のファイルの読み書き。
///
/// ```
/// <出力ディレクトリ>/20261024-153012-kina-mascot/
///   run.json  prompt.txt  stdout.jsonl  stderr.log  last-message.md  kina-mascot-01.png ...
/// ```
enum RunFolder {
    static let recordFileName = "run.json"
    static let promptFileName = "prompt.txt"
    static let stdoutFileName = "stdout.jsonl"
    static let stderrFileName = "stderr.log"
    static let lastMessageFileName = CommandBuilder.lastMessageFileName

    /// 履歴の削除で消す記録ファイル。run.json は最後に消す（途中で失敗しても履歴に残るように）。
    static let recordFileNames = [promptFileName, stdoutFileName, stderrFileName, lastMessageFileName, recordFileName]

    /// 同名フォルダがあったときに試す連番の上限。
    private static let maxSuffix = 9999

    /// `<outputDirectory>/<Slug.folderName(slug:startedAt:)>/` を作って返す。
    /// 出力ディレクトリが無ければ作る。同名があれば `-2`, `-3`, … を付ける。
    ///
    /// 最後のフォルダは mkdir 1 回で作り、既にあれば（EEXIST）次の名前を試す。
    /// 同時に作っても同じフォルダを 2 つのジョブが使うことはない。
    static func create(in outputDirectory: URL, slug: String, startedAt: Date) throws -> URL {
        let base = outputDirectory.standardizedFileURL
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // 古い queue.json などから来たスラッグに `/` が混じっていても、フォルダが入れ子にならないようにする。
        let name = Slug.folderName(slug: Slug.sanitize(slug), startedAt: startedAt)
        for n in 1...maxSuffix {
            let candidate = n == 1 ? name : "\(name)-\(n)"
            let url = base.appendingPathComponent(candidate, isDirectory: true)
            let (rc, code) = url.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
                guard let path else { return (-1, EINVAL) }
                let rc = mkdir(path, 0o777)
                return (rc, rc == 0 ? 0 : errno)
            }
            if rc == 0 {
                return url
            }
            if code == EEXIST {
                continue
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: base.appendingPathComponent(name).path])
    }

    /// run.json を書く（整形済み・キー順固定・日付は ISO 8601・原子的に書き換え）。
    static func writeRecord(_ record: JobRecord, to folder: URL) throws {
        let data = try makeEncoder().encode(record)
        try data.write(to: folder.appendingPathComponent(recordFileName), options: .atomic)
    }

    /// run.json を読む。
    static func readRecord(from folder: URL) throws -> JobRecord {
        let data = try Data(contentsOf: folder.appendingPathComponent(recordFileName))
        return try makeDecoder().decode(JobRecord.self, from: data)
    }

    /// stdout.jsonl と stderr.log の中身（無ければ空文字）。
    static func readLogs(folder: URL) -> (stdout: String, stderr: String) {
        (
            readText(folder.appendingPathComponent(stdoutFileName)),
            readText(folder.appendingPathComponent(stderrFileName))
        )
    }

    /// テキストファイルを読む（無ければ空文字。UTF-8 として読めないバイトは置き換える）。
    static func readText(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 履歴の削除用。run.json / prompt.txt / stdout.jsonl / stderr.log / last-message.md を消し、画像は残す。
    /// フォルダが空になったらフォルダも消す。
    ///
    /// - このプロセスで実行中のジョブが使っているフォルダ（`isInUse`）には触らず throw する。
    /// - フォルダ自体がシンボリックリンクなら、リンク先のファイルを消さないよう throw する。
    /// - 記録ファイルの名前でも、ディレクトリは消さない。シンボリックリンクはリンクだけを消す（リンク先は残す）。
    /// - フォルダは中身が空（`.DS_Store` だけ）のときだけ rmdir する。知らないファイルが残っていれば残す。
    /// - 持ち主（run.json の id）の確認は呼び出し側（`HistoryStore.delete`）で行う。
    static func deleteRecordFiles(folder: URL) throws {
        switch fileKind(folder) {
        case .missing:
            // フォルダごと無ければ消すものも無い。
            return
        case .symlink:
            throw RunFolderError.symlinkedFolder(folder.path)
        case .directory:
            break
        case .file, .other:
            throw RunFolderError.notAFolder(folder.path)
        case .unreachable:
            throw RunFolderError.unreachable(folder.path)
        }
        if isInUse(folder) {
            throw RunFolderError.inUse(folder.path)
        }
        for name in recordFileNames {
            let url = folder.appendingPathComponent(name)
            switch fileKind(url) {
            case .missing, .directory:
                continue
            case .file, .symlink, .other, .unreachable:
                // 調べられないもの（権限など）も消してみて、消せなければ throw する。
                try unlinkItem(url)
            }
        }
        // .DS_Store だけが残っていれば空とみなす。rmdir は空でなければ失敗するので、途中で増えたファイルは消さない。
        // 空のフォルダを消せなくても（親が書き込み禁止など）、記録ファイルは消せたので失敗にはしない。
        guard let rest = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              rest.allSatisfy({ $0 == ".DS_Store" }) else { return }
        let dsStore = folder.appendingPathComponent(".DS_Store")
        if !rest.isEmpty, fileKind(dsStore) == .file {
            try? unlinkItem(dsStore)
        }
        _ = folder.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return rmdir(path)
        }
    }

    // MARK: - 実行中のフォルダ

    /// このプロセスで実行中のジョブが使っているフォルダ（場所のキー → 使っている数）。
    private static let foldersInUse = Mutex<[String: Int]>([:])

    /// 実行を始めたジョブのフォルダとして印を付ける。終わったら必ず `endUse` を呼ぶ。
    /// 印の付いたフォルダは、`HistoryStore.loadAll` が履歴に出さず、`deleteRecordFiles` / `HistoryStore.delete` が消さない。
    static func beginUse(_ folder: URL) {
        let key = HistoryStore.pathKey(folder.path)
        foldersInUse.withLock { $0[key, default: 0] += 1 }
    }

    /// `beginUse` の印を外す。
    static func endUse(_ folder: URL) {
        let key = HistoryStore.pathKey(folder.path)
        foldersInUse.withLock { map in
            let n = (map[key] ?? 0) - 1
            map[key] = n > 0 ? n : nil
        }
    }

    /// このプロセスで実行中のジョブが使っているフォルダか。
    static func isInUse(_ folder: URL) -> Bool {
        let key = HistoryStore.pathKey(folder.path)
        return foldersInUse.withLock { $0[key] != nil }
    }

    // MARK: - 出力フォルダを作れなかったジョブの記録

    /// 出力フォルダを作れなかったジョブの記録を置く場所（`~/Library/Application Support/CodexImageFactory/failed/`）。
    /// 中身は普通のジョブのフォルダと同じ形（run.json と prompt.txt）。`HistoryStore.loadAll` が走査する。
    static var defaultFailedRecordsDirectory: URL {
        PathUtil.applicationSupportDirectory.appendingPathComponent(failedRecordsDirectoryName, isDirectory: true)
    }

    /// 上の場所のフォルダ名（history.json と同じ場所に置く）。
    static let failedRecordsDirectoryName = "failed"

    // MARK: - ファイルの種類

    /// lstat で見たファイルの種類（シンボリックリンクはたどらない）。
    enum FileKind: Equatable {
        case missing
        case directory
        case file
        case symlink
        case other
        /// ENOENT 以外の理由で調べられない（権限・接続切れなど）。
        case unreachable
    }

    static func fileKind(_ url: URL) -> FileKind {
        var st = stat()
        let (rc, code) = url.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
            guard let path else { return (-1, EINVAL) }
            let rc = lstat(path, &st)
            return (rc, rc == 0 ? 0 : errno)
        }
        guard rc == 0 else {
            return code == ENOENT || code == ENOTDIR ? .missing : .unreachable
        }
        switch st.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    /// 1 つのファイル（またはリンク）を消す。ディレクトリは消さない。消す前に無くなっていたら何もしない。
    private static func unlinkItem(_ url: URL) throws {
        let (rc, code) = url.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
            guard let path else { return (-1, EINVAL) }
            let rc = unlink(path)
            return (rc, rc == 0 ? 0 : errno)
        }
        if rc != 0, code != ENOENT {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(isoWithFraction))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                if let date = parseDate(s) {
                    return date
                }
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "日付として読めません: \(s)")
            }
            // 古い形式（JSONEncoder の既定 = 2001-01-01 からの秒数）。
            return Date(timeIntervalSinceReferenceDate: try c.decode(Double.self))
        }
        return decoder
    }

    // MARK: - 日付

    /// 書き出しに使う形式。例: `2026-10-24T06:30:12.345Z`
    private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoWithoutFraction = Date.ISO8601FormatStyle()

    /// ISO 8601 の文字列を読む。小数秒あり・なし、`Z`・`+09:00` のどちらも受け付ける。
    static func parseDate(_ string: String) -> Date? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = try? isoWithFraction.parse(s) { return d }
        if let d = try? isoWithoutFraction.parse(s) { return d }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: s) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: s)
    }
}

/// 記録ファイルを消せない理由。
enum RunFolderError: Error, Equatable, LocalizedError {
    /// このプロセスで実行中のジョブが使っている。
    case inUse(String)
    /// フォルダがシンボリックリンク。
    case symlinkedFolder(String)
    /// フォルダではない。
    case notAFolder(String)
    /// フォルダを調べられない（権限・接続切れなど）。
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .inUse(let path):
            "実行中のジョブのフォルダなので消しませんでした: \(path)"
        case .symlinkedFolder(let path):
            "フォルダがシンボリックリンクなので、リンク先のファイルは消しませんでした: \(path)"
        case .notAFolder(let path):
            "フォルダではないので消しませんでした: \(path)"
        case .unreachable(let path):
            "フォルダを調べられないので消しませんでした: \(path)"
        }
    }
}
