import Darwin
import XCTest
@testable import Hyperterm

/// Which processes a closed session stops, and that a reused pid is never one of them.
final class SessionReaperTests: XCTestCase {
    private let mine: pid_t = 100

    private func entry(_ pid: pid_t, parent: pid_t, start: UInt64 = 1) -> ProcessInspector.ProcessEntry {
        .init(pid: pid, ppid: parent, name: "p\(pid)", startSeconds: 0, start: start)
    }

    private func select(_ table: [ProcessInspector.ProcessEntry], seeds: [pid_t], recorded: [TrackedProcess] = []) -> Set<pid_t> {
        let byPID = Dictionary(uniqueKeysWithValues: table.map { ($0.pid, $0) })
        let tree = ProcessInspector.selectTree(session: "s", seeds: seeds, recorded: recorded, byPID: byPID,
                                               children: Dictionary(grouping: table, by: \.ppid), mine: mine)
        return Set(tree.map(\.pid))
    }

    func testTreeKeepsRecordedOrphansAndTheirChildren() {
        // 200 is a terminal root (login); 201 the shell; 300 a daemon that left for launchd.
        let table = [entry(mine, parent: 1), entry(200, parent: mine), entry(201, parent: 200),
                     entry(202, parent: 201), entry(300, parent: 1, start: 7), entry(301, parent: 300),
                     entry(400, parent: 1)]
        let recorded = [TrackedProcess(pid: 300, start: 7, session: "s")]
        XCTAssertEqual(select(table, seeds: [201, 202], recorded: recorded), [201, 202, 300, 301])
    }

    func testTreeNeverIncludesKuronamiOrItsChildren() {
        // A Chromium helper (500) and another session's root (200) are Kuronami's children.
        let table = [entry(mine, parent: 1), entry(200, parent: mine), entry(201, parent: 200),
                     entry(500, parent: mine), entry(501, parent: 500)]
        XCTAssertEqual(select(table, seeds: [mine, 200, 500, 1]), [])
    }

    func testTreeDropsRecordedPidReusedByAnotherProcess() {
        let table = [entry(300, parent: 1, start: 9), entry(301, parent: 300)]
        let recorded = [TrackedProcess(pid: 300, start: 7, session: "s")]
        XCTAssertEqual(select(table, seeds: [], recorded: recorded), [])
    }

    func testSignalGuard() {
        let process = TrackedProcess(pid: 300, start: 7, session: "s")
        let same = ProcessFacts(start: 7, ppid: 1, pgid: 300, name: "node")
        XCTAssertTrue(SessionReaper.maySignal(process, same, mine: mine))
        XCTAssertFalse(SessionReaper.maySignal(process, ProcessFacts(start: 8, ppid: 1, pgid: 300, name: "node"), mine: mine))
        XCTAssertFalse(SessionReaper.maySignal(process, nil, mine: mine))
        XCTAssertFalse(SessionReaper.maySignal(process, ProcessFacts(start: 7, ppid: mine, pgid: 300, name: "Helper"), mine: mine))
        XCTAssertFalse(SessionReaper.maySignal(TrackedProcess(pid: mine, start: 7, session: "s"), same, mine: mine))
        XCTAssertFalse(SessionReaper.maySignal(TrackedProcess(pid: 1, start: 7, session: "s"), same, mine: mine))
    }

    func testSweepTakesOrphansAndTheirRecordedChildrenOnly() {
        let facts: [pid_t: ProcessFacts] = [
            10: ProcessFacts(start: 1, ppid: 1, pgid: 10, name: "node"),     // orphaned leftover
            11: ProcessFacts(start: 1, ppid: 10, pgid: 10, name: "esbuild"), // its child
            20: ProcessFacts(start: 1, ppid: 55, pgid: 20, name: "sleep"),   // parent still alive
            30: ProcessFacts(start: 2, ppid: 1, pgid: 30, name: "other"),    // pid reused
        ]
        let recorded = [10, 11, 20, 30, 40].map { TrackedProcess(pid: $0, start: 1, session: "s") }
        let swept = SessionReaper.leftovers(recorded, facts: { facts[$0] })
        XCTAssertEqual(Set(swept.map(\.pid)), [10, 11])
    }

    // MARK: - Real processes

    /// `sh -c 'sleep & sleep &'` in its own session: the shell exits and both sleeps are left
    /// to launchd, like a nohup'd job after its terminal closed. One also ignores SIGTERM.
    private func spawnOrphans() throws -> [pid_t] {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in [0, 1, 2] { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: out) }
        let script = "sleep 300 & a=$!; trap '' TERM; sleep 301 & echo $a $! > \"$0\""
        let argv: [UnsafeMutablePointer<CChar>?] = ["/bin/sh", "-c", script, out].map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var shell: pid_t = 0
        XCTAssertEqual(posix_spawn(&shell, "/bin/sh", &actions, &attributes, argv, environ), 0)
        var status: Int32 = 0
        waitpid(shell, &status, 0)
        let output = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
        let pids = output.split(separator: " ").compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        XCTAssertEqual(pids.count, 2)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !pids.allSatisfy({ SessionReaper.facts($0)?.ppid == 1 }) { usleep(20_000) }
        return pids
    }

    private func waitUntilGone(_ pids: [pid_t], timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pids.allSatisfy({ SessionReaper.facts($0) == nil }) { return true }
            usleep(50_000)
        }
        return false
    }

    func testStopsDetachedJobsIncludingOneIgnoringTerm() throws {
        let pids = try spawnOrphans()
        let recorded = pids.compactMap { pid in SessionReaper.facts(pid).map { TrackedProcess(pid: pid, start: $0.start, session: "s") } }
        XCTAssertEqual(Set(SessionReaper.leftovers(recorded, facts: SessionReaper.facts).map(\.pid)), Set(pids))

        let done = expectation(description: "stopped")
        SessionReaper.stop(recorded, grace: 0.5) { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(waitUntilGone(pids))
    }

    func testStopLeavesAProcessWhoseStartTimeDiffers() throws {
        let pids = try spawnOrphans()
        defer { pids.forEach { kill($0, SIGKILL) } }
        let stale = pids.compactMap { pid in SessionReaper.facts(pid).map { TrackedProcess(pid: pid, start: $0.start + 1, session: "s") } }
        XCTAssertEqual(stale.count, 2, "\(pids.map { SessionReaper.facts($0) as Any })")

        let done = expectation(description: "stopped")
        SessionReaper.stop(stale, grace: 0.2) { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(pids.allSatisfy { SessionReaper.facts($0) != nil })
    }
}
