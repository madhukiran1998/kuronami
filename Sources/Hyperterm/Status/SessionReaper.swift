import Darwin
import Foundation

/// One process a session started. The start time tells it apart from a later process that
/// reuses the pid.
struct TrackedProcess: Codable, Hashable, Sendable {
    let pid: pid_t
    /// Microseconds since the epoch.
    let start: UInt64
    let session: String
}

/// Kernel facts about a live process, from proc_pidinfo.
struct ProcessFacts: Equatable, Sendable {
    let start: UInt64
    let ppid: pid_t
    let pgid: pid_t
    let name: String
}

/// The processes recorded by the run that wrote it, so the next launch can sweep what it left.
struct ProcessLedger: Codable {
    let ownerPID: pid_t
    let ownerStart: UInt64
    let processes: [TrackedProcess]

    static let url = ControlPaths.supportDirectory.appendingPathComponent("processes.json")
}

/// Stops what sessions started. Closing a terminal hangs up its shell, but jobs that left it
/// (nohup, setsid, double-forked daemons) would otherwise run on under launchd.
enum SessionReaper {
    private static let queue = DispatchQueue(label: "dev.hyperterm.reaper", qos: .utility)

    static func facts(_ pid: pid_t) -> ProcessFacts? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_pid == UInt32(pid) else { return nil }
        let name = withUnsafeBytes(of: &info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return ProcessFacts(start: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
                            ppid: pid_t(info.pbi_ppid), pgid: pid_t(info.pbi_pgid), name: name)
    }

    /// Recorded processes that are still running and orphaned to launchd, with their recorded
    /// descendants (they'd be orphaned the moment their parent stops).
    static func leftovers(_ recorded: [TrackedProcess], facts: (pid_t) -> ProcessFacts?) -> [TrackedProcess] {
        let alive = recorded.compactMap { process in
            facts(process.pid).flatMap { $0.start == process.start ? (process, $0) : nil }
        }
        var orphaned = Set(alive.filter { $0.1.ppid == 1 }.map(\.0.pid))
        var grew = true
        while grew {
            grew = false
            for (process, info) in alive where !orphaned.contains(process.pid) && orphaned.contains(info.ppid) {
                orphaned.insert(process.pid)
                grew = true
            }
        }
        return alive.map(\.0).filter { orphaned.contains($0.pid) }
    }

    /// Whether a signal may go to `process`: the same process that was recorded, and never
    /// Tako or its direct children (terminal roots, Chromium helpers).
    static func maySignal(_ process: TrackedProcess, _ info: ProcessFacts?, mine: pid_t) -> Bool {
        guard let info, process.pid > 1, process.pid != mine else { return false }
        return info.start == process.start && info.ppid != mine
    }

    /// SIGTERM now and SIGKILL whatever is left after `grace`, off the main thread.
    static func stop(_ processes: [TrackedProcess], grace: TimeInterval = 2, completion: (@Sendable () -> Void)? = nil) {
        guard !processes.isEmpty else { completion?(); return }
        queue.async {
            signal(processes, SIGTERM)
            queue.asyncAfter(deadline: .now() + grace) {
                signal(processes, SIGKILL)
                completion?()
            }
        }
    }

    /// Each signal re-checks the start time first, so a pid reused since is never touched.
    private static func signal(_ processes: [TrackedProcess], _ signal: Int32) {
        let mine = getpid()
        for process in processes {
            let info = facts(process.pid)
            guard maySignal(process, info, mine: mine), let info else { continue }
            // A group led by a recorded process also holds what it forked since the walk.
            if info.pgid == process.pid { killpg(process.pid, signal) }
            kill(process.pid, signal)
        }
    }

    /// At launch, before sessions restore: stops what an earlier run that quit or crashed left
    /// running, and notes each in hooks.log.
    static func sweepLeftovers(ledger url: URL = ProcessLedger.url) {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(ProcessLedger.self, from: data) else { return }
        if let owner = facts(ledger.ownerPID), owner.start == ledger.ownerStart { return }
        try? FileManager.default.removeItem(at: url)
        let found = leftovers(ledger.processes, facts: facts)
        for process in found {
            let name = facts(process.pid)?.name ?? "?"
            HookLog.append(source: "sweep", sessionID: process.session, payload: "stopped leftover \(name) pid \(process.pid)")
        }
        stop(found)
    }
}
