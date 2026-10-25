import Foundation

/// 待機中ジョブの永続化（`~/Library/Application Support/CodexImageFactory/queue.json`）。
struct QueueStore: Sendable {
    var fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static var `default`: QueueStore {
        QueueStore(fileURL: PathUtil.applicationSupportDirectory.appendingPathComponent("queue.json"))
    }

    /// 保存済みの待機中ジョブ。無い・読めないときは空。
    /// 配列全体を読めなければ 1 件ずつ読み、壊れた要素だけを捨てる。
    func load() -> [JobRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = RunFolder.makeDecoder()
        if let jobs = try? decoder.decode([JobRecord].self, from: data) {
            return jobs
        }
        guard let items = try? decoder.decode([QueueStoreLossyRecord].self, from: data) else {
            return []
        }
        return items.compactMap(\.record)
    }

    /// 待機中ジョブを保存する（親フォルダが無ければ作る・原子的に書き換え）。
    /// 失敗してもアプリは止めない（次の変更でまた書く）。
    func save(_ jobs: [JobRecord]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try RunFolder.makeEncoder().encode(jobs)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("CodexImageFactory: queue.json を保存できませんでした: %@", error.localizedDescription)
        }
    }
}

/// 1 件ずつ読むための包み。読めない要素は nil にして先へ進む。
private struct QueueStoreLossyRecord: Decodable {
    let record: JobRecord?

    init(from decoder: any Decoder) throws {
        record = try? JobRecord(from: decoder)
    }
}
