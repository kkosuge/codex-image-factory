import Darwin

/// プロセス表（sysctl KERN_PROC_ALL）を読んで、子孫プロセスを探して止める。
///
/// codex は `/bin/zsh -lc ...` などの子を起動するので、中止で SIGKILL するときは子孫もまとめて止める。
/// PID の使い回しで無関係なプロセスを止めないよう、PID と開始時刻の組で同じプロセスか確かめてから送る。
enum ProcessSupportProcessTree {
    /// プロセス 1 つ分の情報。
    struct Entry: Hashable, Sendable {
        var pid: pid_t
        var parentPid: pid_t
        var groupId: pid_t
        var startSeconds: Int
        var startMicroseconds: Int32
        var isZombie: Bool

        /// 同じプロセスか（PID と開始時刻が一致するか）。
        func isSameProcess(as other: Entry) -> Bool {
            pid == other.pid && startSeconds == other.startSeconds && startMicroseconds == other.startMicroseconds
        }
    }

    /// 今のプロセス表。読めなければ空。
    static func snapshot() -> [Entry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        // 読む間にプロセスが増えると ENOMEM になるので、少し余裕を持って何度か試す。
        for attempt in 0..<4 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
            let capacity = size / stride + 64 * (attempt + 1)
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            var bytes = capacity * stride
            let rc = procs.withUnsafeMutableBytes { raw in
                sysctl(&mib, u_int(mib.count), raw.baseAddress, &bytes, nil, 0)
            }
            if rc != 0 {
                if errno == ENOMEM { continue }
                return []
            }
            let count = min(capacity, bytes / stride)
            return procs.prefix(count).map(Entry.init(info:))
        }
        return []
    }

    /// 1 つのプロセスの情報。いなければ nil。
    static func entry(for pid: pid_t) -> Entry? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard rc == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return Entry(info: info)
    }

    /// `root` の子孫（root 自身は含まない）。親から近い順。
    static func descendants(of root: pid_t, in table: [Entry]) -> [Entry] {
        guard root > 1 else { return [] }
        var children: [pid_t: [Entry]] = [:]
        for entry in table where entry.pid > 1 && entry.pid != entry.parentPid {
            children[entry.parentPid, default: []].append(entry)
        }
        var result: [Entry] = []
        var visited: Set<pid_t> = [root]
        var queue: [pid_t] = [root]
        var index = 0
        while index < queue.count {
            let parent = queue[index]
            index += 1
            for child in children[parent] ?? [] where !visited.contains(child.pid) {
                visited.insert(child.pid)
                result.append(child)
                queue.append(child.pid)
            }
        }
        return result
    }

    static func descendants(of root: pid_t) -> [Entry] {
        descendants(of: root, in: snapshot())
    }

    /// `entries` のうち、まだ同じプロセスとして生きているものにシグナルを送る。
    static func signalIfStillRunning(_ entries: [Entry], signal: Int32) {
        guard !entries.isEmpty else { return }
        var current: [pid_t: Entry] = [:]
        for entry in snapshot() {
            current[entry.pid] = entry
        }
        var sent: Set<pid_t> = []
        for entry in entries where !sent.contains(entry.pid) {
            guard let now = current[entry.pid], now.isSameProcess(as: entry), !now.isZombie else { continue }
            if send(signal, to: entry.pid) {
                sent.insert(entry.pid)
            }
        }
    }

    /// 1 つのプロセスにシグナルを送る。PID 0・1・負の値と自分自身には送らない（kill(0) や kill(-1) の事故を防ぐ）。
    @discardableResult
    static func send(_ signal: Int32, to pid: pid_t) -> Bool {
        guard pid > 1, pid != getpid() else { return false }
        return kill(pid, signal) == 0
    }

    /// プロセスグループ全体にシグナルを送る。自分のグループには送らない。
    @discardableResult
    static func sendToGroup(_ signal: Int32, groupId: pid_t) -> Bool {
        guard groupId > 1, groupId != getpgrp(), groupId != getpid() else { return false }
        return killpg(groupId, signal) == 0
    }

    /// 生きているか（ゾンビは止まったものとみなす）。
    static func isRunning(_ pid: pid_t) -> Bool {
        guard let entry = entry(for: pid) else { return false }
        return !entry.isZombie
    }
}

private extension ProcessSupportProcessTree.Entry {
    init(info: kinfo_proc) {
        let start = info.kp_proc.p_un.__p_starttime
        self.init(
            pid: info.kp_proc.p_pid,
            parentPid: info.kp_eproc.e_ppid,
            groupId: info.kp_eproc.e_pgid,
            startSeconds: Int(start.tv_sec),
            startMicroseconds: Int32(start.tv_usec),
            isZombie: Int32(info.kp_proc.p_stat) == SZOMB
        )
    }
}
