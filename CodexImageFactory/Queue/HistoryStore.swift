import Foundation

/// 履歴の索引。中身は各フォルダの run.json を正とし、索引はフォルダの場所だけを持つ。
/// 索引を消しても、出力ディレクトリ（と、出力フォルダを作れなかったジョブの記録の置き場所）を走査して履歴を復元できる。
///
/// 実行中のジョブとの約束:
/// - このプロセスで実行中のジョブのフォルダ（`RunFolder.isInUse`）は `loadAll` で返さない（索引には残す）。
///   終わったジョブは呼び出し側が `register` するので、そのあとの読み込みから履歴に出る。
/// - `delete` は実行中のジョブのフォルダを決して消さない。run.json が `running` / `queued` のまま残っているフォルダ
///   （前回の異常終了か、別に起動しているアプリが実行中）は、`allowingInterrupted: true` のときだけ消す。
///   呼び出し側は、自分のキューで実行中・待機中でないと確かめた記録にだけ true を渡すこと。
/// - `delete` が記録ファイルを消すのは、フォルダの run.json がこのアプリの書いたもので、id が消す記録と同じときだけ。
struct HistoryStore: Sendable {
    /// `~/Library/Application Support/CodexImageFactory/history.json`（フォルダの絶対パスの配列）
    var indexURL: URL
    /// 出力フォルダを作れなかったジョブの記録の置き場所（`JobExecutor.failedRecordsDirectory` と同じ場所）。
    /// `loadAll` はここも走査する。nil なら走査しない。
    var failedRecordsDirectory: URL?

    /// run.json が実行中・待機中のまま残っていたときの要約。
    static let interruptedSummary = "アプリの終了などで中断されました"

    /// 失敗記録の置き場所は索引と同じフォルダの `failed/`（既定の場所なら `RunFolder.defaultFailedRecordsDirectory`）。
    init(indexURL: URL) {
        self.init(
            indexURL: indexURL,
            failedRecordsDirectory: indexURL.deletingLastPathComponent()
                .appendingPathComponent(RunFolder.failedRecordsDirectoryName, isDirectory: true)
        )
    }

    init(indexURL: URL, failedRecordsDirectory: URL?) {
        self.indexURL = indexURL
        self.failedRecordsDirectory = failedRecordsDirectory
    }

    static var `default`: HistoryStore {
        HistoryStore(indexURL: PathUtil.applicationSupportDirectory.appendingPathComponent("history.json"))
    }

    /// 索引にあるフォルダと、`outputDirectory` 直下・失敗記録の置き場所の直下で run.json を持つフォルダを読み、新しい順に返す。
    /// 同じ id は 1 件にまとめる。run.json が `running` / `queued` のまま残っていたもの（前回の異常終了）は
    /// `cancelled` として返す（ファイルは書き換えない）。走査で見つけたフォルダは索引に足す。
    /// このプロセスで実行中のジョブのフォルダは返さない。
    func loadAll(outputDirectory: URL) -> [JobRecord] {
        loadAll(outputDirectory: outputDirectory, excluding: [])
    }

    /// `loadAll(outputDirectory:)` と同じ。ただし `excludedIDs` の記録（呼び出し側のキューで実行中・待機中のもの）は
    /// 返さない（中断扱いにもしない）。そのフォルダは索引に残す。
    func loadAll(outputDirectory: URL, excluding excludedIDs: Set<UUID>) -> [JobRecord] {
        let outDir = outputDirectory.standardizedFileURL
        let outDirKey = Self.pathKey(outDir.path)

        // 候補のフォルダ（索引 → 走査の順。同じ場所は 1 回だけ）。
        var candidates: [URL] = []
        var seen = Set<String>()
        func addCandidate(_ url: URL) {
            if seen.insert(Self.pathKey(url.path)).inserted {
                candidates.append(url)
            }
        }
        for path in readIndex() where !path.isEmpty {
            addCandidate(URL(fileURLWithPath: PathUtil.expandTilde(path), isDirectory: true).standardizedFileURL)
        }
        Self.runFolders(in: outDir).forEach(addCandidate)
        if let failedRecordsDirectory {
            Self.runFolders(in: failedRecordsDirectory.standardizedFileURL).forEach(addCandidate)
        }

        // run.json を読む。履歴に出さないが索引からは落とさないもの（読めない・調べられない・実行中）は kept に入れる。
        var entries: [HistoryStoreEntry] = []
        var kept: [URL] = []
        for folder in candidates {
            switch RunFolder.fileKind(folder.appendingPathComponent(RunFolder.recordFileName)) {
            case .missing:
                // 親フォルダがあるのに無い = 消された。親ごと見えない（外付けやネットワークのボリュームが外れている）なら残す。
                if !Self.isReachableDirectory(folder.deletingLastPathComponent()) {
                    kept.append(folder)
                }
                continue
            case .unreachable:
                kept.append(folder)
                continue
            case .file, .symlink, .directory, .other:
                break
            }
            if RunFolder.isInUse(folder) {
                kept.append(folder)
                continue
            }
            guard var record = try? RunFolder.readRecord(from: folder) else {
                kept.append(folder)
                continue
            }
            // このアプリが書いたと確かめられない run.json（手で作った・壊れた）は履歴に出さない。
            // 出すと delete が断るので、消せない行が残り続けてしまう。
            guard Self.isOwnRecord(folder) else {
                kept.append(folder)
                continue
            }
            if excludedIDs.contains(record.id) {
                kept.append(folder)
                continue
            }
            Self.fixUp(&record, folder: folder)
            let inside = Self.pathKey(folder.deletingLastPathComponent().path) == outDirKey
            entries.append(HistoryStoreEntry(record: record, folder: folder, insideOutputDirectory: inside))
        }

        // 同じ id は 1 件に（出力ディレクトリ内のものを優先し、次に新しいもの）。
        var best: [UUID: HistoryStoreEntry] = [:]
        for entry in entries {
            if let current = best[entry.record.id], !entry.isPreferred(over: current) {
                continue
            }
            best[entry.record.id] = entry
        }
        let sorted = best.values.sorted { $0.isNewer(than: $1) }

        let newIndex = sorted.map(\.folder.path) + kept.map(\.path)
        if newIndex != readIndex() {
            writeIndex(newIndex)
        }
        return sorted.map(\.record)
    }

    /// 終わったジョブのフォルダを索引に足す。
    func register(_ record: JobRecord) {
        let dir = record.outputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return }
        let path = URL(fileURLWithPath: PathUtil.expandTilde(dir), isDirectory: true).standardizedFileURL.path
        var paths = readIndex()
        let key = Self.pathKey(path)
        guard !paths.contains(where: { Self.pathKey($0) == key }) else { return }
        paths.insert(path, at: 0)
        writeIndex(paths)
    }

    /// 履歴から消す。`delete(_:allowingInterrupted: false)` と同じ。
    func delete(_ record: JobRecord) throws {
        try delete(record, allowingInterrupted: false)
    }

    /// 履歴から消す。索引から外し、`RunFolder.deleteRecordFiles` で記録ファイルを消す（画像と知らないファイルは残す）。
    ///
    /// 記録ファイルを消すのは、フォルダの run.json がこのアプリの書いたもので、id が `record.id` と同じときだけ。
    /// 次のときは何も消さずに throw し、索引もそのままにする:
    /// - このプロセスで実行中のジョブのフォルダ（`RunFolder.isInUse`）
    /// - run.json が `running` / `queued` のまま（`allowingInterrupted` が false のとき）
    /// - run.json が読めない・このアプリのものと確かめられない・id が違う
    /// - フォルダがシンボリックリンク（リンク先は消さない）
    ///
    /// ファイルを消せなかったとき（権限など）も throw し、索引はそのままにする。
    /// run.json は最後に消すので、途中で失敗しても次の読み込みで履歴に残る。
    ///
    /// フォルダや run.json がもう無ければ、ファイルには触らず索引から外すだけ。
    func delete(_ record: JobRecord, allowingInterrupted: Bool) throws {
        let dir = record.outputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return }
        let folder = URL(fileURLWithPath: PathUtil.expandTilde(dir), isDirectory: true).standardizedFileURL
        if try Self.checkDeletable(folder: folder, id: record.id, allowingInterrupted: allowingInterrupted) {
            try RunFolder.deleteRecordFiles(folder: folder)
        }
        var paths = readIndex()
        let key = Self.pathKey(folder.path)
        let before = paths.count
        paths.removeAll { Self.pathKey($0) == key }
        if paths.count != before {
            writeIndex(paths)
        }
    }

    /// 記録ファイルを消してよいか確かめる。消してよければ true、消すものが無ければ false、だめなら throw。
    static func checkDeletable(folder: URL, id: UUID, allowingInterrupted: Bool) throws -> Bool {
        switch RunFolder.fileKind(folder) {
        case .missing:
            return false
        case .symlink:
            throw RunFolderError.symlinkedFolder(folder.path)
        case .file, .other:
            throw RunFolderError.notAFolder(folder.path)
        case .unreachable:
            throw RunFolderError.unreachable(folder.path)
        case .directory:
            break
        }
        if RunFolder.isInUse(folder) {
            throw RunFolderError.inUse(folder.path)
        }
        let recordURL = folder.appendingPathComponent(RunFolder.recordFileName)
        switch RunFolder.fileKind(recordURL) {
        case .missing:
            // 持ち主を確かめられないので、ファイルには触らない。
            return false
        case .unreachable:
            throw RunFolderError.unreachable(recordURL.path)
        case .file, .symlink, .directory, .other:
            break
        }
        guard let data = try? Data(contentsOf: recordURL) else {
            throw HistoryStoreError.unreadableRecord(folder.path)
        }
        guard let marker = try? RunFolder.makeDecoder().decode(HistoryStoreOwnershipMarker.self, from: data) else {
            throw HistoryStoreError.notOurRecord(folder.path)
        }
        guard marker.id == id else {
            throw HistoryStoreError.recordMismatch(folder.path)
        }
        if !marker.status.isFinished, !allowingInterrupted {
            throw HistoryStoreError.stillRunning(folder.path)
        }
        return true
    }

    /// `directory` 直下で run.json を持つフォルダ（名前順。隠しフォルダは除く）。
    private static func runFolders(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var result: [URL] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let url = directory.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
                  fm.fileExists(atPath: url.appendingPathComponent(RunFolder.recordFileName).path) else {
                continue
            }
            result.append(url)
        }
        return result
    }

    /// 調べられるディレクトリか（シンボリックリンクはたどる）。
    private static func isReachableDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - 索引ファイル

    private func readIndex() -> [String] {
        guard let data = try? Data(contentsOf: indexURL),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return paths
    }

    private func writeIndex(_ paths: [String]) {
        do {
            try FileManager.default.createDirectory(
                at: indexURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(paths).write(to: indexURL, options: .atomic)
        } catch {
            NSLog("CodexImageFactory: history.json を保存できませんでした: %@", error.localizedDescription)
        }
    }

    // MARK: - 補正

    /// 読んだ記録をフォルダの実態に合わせる（メモリ上だけ。run.json は書き換えない）。
    static func fixUp(_ record: inout JobRecord, folder: URL) {
        let fm = FileManager.default
        record.outputDir = folder.path
        record.images = record.images.map { path in
            if path.hasPrefix("/"), fm.fileExists(atPath: path) {
                return path
            }
            if !path.hasPrefix("/") {
                let relative = folder.appendingPathComponent(path).path
                if fm.fileExists(atPath: relative) { return relative }
            }
            // フォルダごと移動・コピーされた場合は、同じ名前のファイルがフォルダにあればそちらを使う。
            let local = folder.appendingPathComponent((path as NSString).lastPathComponent).path
            if fm.fileExists(atPath: local) { return local }
            return path
        }
        if record.status == .running || record.status == .queued {
            record.status = .cancelled
            if record.errorSummary == nil {
                record.errorSummary = interruptedSummary
            }
        }
    }

    /// 同じ場所かどうかを比べるためのキー（`/tmp` と `/private/tmp` のような違いを吸収する）。
    static func pathKey(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// 履歴の削除を断った理由。
enum HistoryStoreError: Error, Equatable, LocalizedError {
    case unreadableRecord(String)
    case notOurRecord(String)
    case recordMismatch(String)
    case stillRunning(String)

    var errorDescription: String? {
        switch self {
        case .unreadableRecord(let path):
            "run.json を読めないので消しませんでした: \(path)"
        case .notOurRecord(let path):
            "このアプリが書いた run.json と確かめられないので消しませんでした: \(path)"
        case .recordMismatch(let path):
            "フォルダの run.json が別のジョブのものに変わっているので消しませんでした: \(path)"
        case .stillRunning(let path):
            "run.json が「実行中」か「待機中」のままなので消しませんでした（別に起動しているアプリが使っている可能性があります）: \(path)"
        }
    }
}

extension HistoryStore {
    /// フォルダの run.json が、このアプリの書いた形（必ず入るキーがそろっている）か。
    static func isOwnRecord(_ folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(RunFolder.recordFileName)) else {
            return false
        }
        return (try? RunFolder.makeDecoder().decode(HistoryStoreOwnershipMarker.self, from: data)) != nil
    }
}

/// このアプリが書いた run.json かを確かめる印。JobRecord を書くと必ず入るキーがそろっていること。
/// （JobRecord 自体の読み込みは、手で直した run.json も読めるように id 以外を省略可にしている）
private struct HistoryStoreOwnershipMarker: Decodable {
    var id: UUID
    var status: JobStatus
    var createdAt: Date
    var slug: String
    var command: [String]
    var commandLine: String
    var outputDir: String
}

/// 読み込んだ 1 件と、その置き場所。
private struct HistoryStoreEntry {
    var record: JobRecord
    var folder: URL
    var insideOutputDirectory: Bool

    /// 並べ替えの基準（開始時刻、無ければ追加時刻）。
    var sortDate: Date { record.startedAt ?? record.createdAt }

    /// 同じ id が複数あったときに、こちらを残すか。
    func isPreferred(over other: HistoryStoreEntry) -> Bool {
        if insideOutputDirectory != other.insideOutputDirectory {
            return insideOutputDirectory
        }
        let mine = record.finishedAt ?? record.startedAt ?? record.createdAt
        let theirs = other.record.finishedAt ?? other.record.startedAt ?? other.record.createdAt
        return mine > theirs
    }

    /// 新しい順に並べるための比較。
    func isNewer(than other: HistoryStoreEntry) -> Bool {
        if sortDate != other.sortDate { return sortDate > other.sortDate }
        if record.createdAt != other.record.createdAt { return record.createdAt > other.record.createdAt }
        return folder.path > other.folder.path
    }
}
