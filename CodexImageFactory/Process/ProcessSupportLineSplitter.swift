import Foundation
import Synchronization

/// バイト列を改行（0x0A）で 1 行ずつに分ける。
///
/// - 分けるのはバイト単位。UTF-8 の多バイト文字に 0x0A は現れないので、文字の途中で切れることはない。
/// - 行末の `\r` は 1 つだけ落とす。
/// - 改行が来るまでのバイトは持ち越す（読み込みの切れ目に左右されない）。
/// - 復号は UTF-8。壊れたバイトは置換文字にする。
struct ProcessSupportLineSplitter: Sendable {
    private var pending: [UInt8] = []

    init() {}

    /// 持ち越し中のバイト数。
    var pendingByteCount: Int { pending.count }

    /// 届いたバイトを足し、できあがった行を返す。
    mutating func append(_ data: Data) -> [String] {
        data.withUnsafeBytes { raw in
            append(bytes: raw.bindMemory(to: UInt8.self))
        }
    }

    mutating func append(_ bytes: [UInt8]) -> [String] {
        bytes.withUnsafeBufferPointer { append(bytes: $0) }
    }

    /// EOF。改行で終わっていない最後の行があれば返す。
    mutating func finish() -> String? {
        guard !pending.isEmpty else { return nil }
        let line = Self.decode(pending[...])
        pending.removeAll()
        return line
    }

    private mutating func append(bytes: UnsafeBufferPointer<UInt8>) -> [String] {
        var lines: [String] = []
        var start = 0
        for i in 0..<bytes.count where bytes[i] == 0x0A {
            let piece = UnsafeBufferPointer(rebasing: bytes[start..<i])
            if pending.isEmpty {
                lines.append(Self.decode(piece))
            } else {
                pending.append(contentsOf: piece)
                lines.append(Self.decode(pending[...]))
                pending.removeAll(keepingCapacity: pending.count <= 64 * 1024)
            }
            start = i + 1
        }
        if start < bytes.count {
            pending.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[start..<bytes.count]))
        }
        return lines
    }

    private static func decode<C: BidirectionalCollection<UInt8>>(_ bytes: C) -> String {
        if let last = bytes.last, last == 0x0D {
            return String(decoding: bytes.dropLast(), as: UTF8.self)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// 1 本のストリームの行分けと受け渡し。
///
/// `append` / `finish` は同じストリームについては順番に呼ばれる（パイプごとの直列キューから呼ぶ）前提。
/// 分割器は Mutex で守り、`onLine` はロックの外で呼ぶ。
final class ProcessSupportLineSink: Sendable {
    private let stream: CodexStream
    private let splitter = Mutex(ProcessSupportLineSplitter())
    private let onLine: @Sendable (CodexStream, String) -> Void

    init(stream: CodexStream, onLine: @escaping @Sendable (CodexStream, String) -> Void) {
        self.stream = stream
        self.onLine = onLine
    }

    func append(_ data: Data) {
        let lines = splitter.withLock { $0.append(data) }
        for line in lines {
            onLine(stream, line)
        }
    }

    func finish() {
        if let last = splitter.withLock({ $0.finish() }) {
            onLine(stream, last)
        }
    }
}

/// 出力をまとめて受け取る入れ物（runCapture 用）。上限を超えた分は捨てる。
final class ProcessSupportDataBox: Sendable {
    private let storage = Mutex(Data())
    private let limit: Int

    init(limit: Int = 8 * 1024 * 1024) {
        self.limit = limit
    }

    func append(_ data: Data) {
        storage.withLock { buffer in
            let room = limit - buffer.count
            guard room > 0 else { return }
            buffer.append(data.count <= room ? data : data.prefix(room))
        }
    }

    var data: Data {
        storage.withLock { $0 }
    }
}
