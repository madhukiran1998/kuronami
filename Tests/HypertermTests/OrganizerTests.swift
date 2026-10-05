import XCTest
@testable import Hyperterm

/// The organizer behind the sidebar's box. Only paths that write nothing to disk or defaults:
/// the test host shares the app's.
@MainActor
final class OrganizerTests: XCTestCase {
    func testOrganizerTakesNoTileAndNoCard() {
        let api = agent("api"), web = agent("web"), organizer = agent("organizer", organizer: true)
        let store = SessionStore(previewSessions: [api, organizer, web], previewLayout: .grid)

        XCTAssertTrue(store.organizer === organizer)
        XCTAssertFalse(store.visibleIDs.contains(organizer.id))
        XCTAssertEqual(Set(store.visibleIDs), [api.id, web.id])
        XCTAssertFalse(store.projects.flatMap(\.agents).contains { $0 === organizer })
        XCTAssertEqual(organizer.info().organizer, true)
        XCTAssertNil(api.info().organizer)
    }

    func testChoosingTheOrganizerOpensItsPanelInsteadOfATile() {
        let api = agent("api"), organizer = agent("organizer", organizer: true)
        let store = SessionStore(previewSessions: [api, organizer], previewLayout: .focus)
        store.select(api)
        var opened = 0
        store.onShowOrganizer = { opened += 1 }

        store.select(organizer)

        XCTAssertEqual(opened, 1)
        XCTAssertEqual(store.selectedID, api.id)
        XCTAssertEqual(store.visibleIDs, [api.id])
    }

    func testWatchedAgentFinishingTellsTheOrganizerOnce() {
        let api = agent("api", state: .idle), organizer = agent("organizer", organizer: true, state: .needsInput("busy"))
        let store = SessionStore(previewSessions: [api, organizer], previewLayout: .grid)
        api.summary = "Added /orders.\nTests pass."
        store.organizerWatches[api.id] = "tell @web the endpoint is ready"

        store.reportToOrganizer(api, from: .working)
        store.reportToOrganizer(api, from: .working)

        // Queued because the organizer is at a prompt; one line, so it can't submit early.
        XCTAssertEqual(organizer.pendingMessages.count, 1)
        let report = organizer.pendingMessages.first ?? ""
        XCTAssertTrue(report.contains("@api finished: Added /orders. Tests pass."), report)
        XCTAssertTrue(report.contains("tell @web the endpoint is ready"), report)
        XCTAssertFalse(report.contains("\n"))
        XCTAssertNil(store.organizerWatches[api.id])
    }

    func testWatchWaitsThroughStatesThatAreNotAFinish() {
        let api = agent("api", state: .working), organizer = agent("organizer", organizer: true, state: .needsInput("busy"))
        let store = SessionStore(previewSessions: [api, organizer], previewLayout: .grid)
        store.organizerWatches[api.id] = "next"

        store.reportToOrganizer(api, from: .idle)

        XCTAssertTrue(organizer.pendingMessages.isEmpty)
        XCTAssertEqual(store.organizerWatches[api.id], "next")
    }

    func testTileSpecsDecodeFromTheWire() throws {
        let json = #"{"split":"row","sizes":[2,1],"children":[{"terminal":"api"},{"split":"column","children":[{"terminal":"web"},{"terminal":"fix"}]}]}"#
        let spec = try JSONDecoder().decode(TileSpec.self, from: Data(json.utf8))
        XCTAssertEqual(spec.split, "row")
        XCTAssertEqual(spec.sizes, [2, 1])
        XCTAssertEqual(spec.children?.first?.terminal, "api")
        XCTAssertEqual(spec.children?.last?.children?.map(\.terminal), ["web", "fix"])
    }

    func testHistoryDescribesEachClosedSessionOnItsOwnLines() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var api = LaunchSpec(label: "api", kind: .claude, cwd: "/workspace/atlas")
        api.createdAt = now.addingTimeInterval(-3 * 3600)
        api.agentSessionId = "abc"
        api.worktreeBranch = "kuronami/api"
        api.summary = "Added /orders.\nTests pass."
        api.memory = SessionMemory(task: "Add an orders endpoint", closedAt: now.addingTimeInterval(-600),
                                   finalState: "Idle", events: ["Ran tests", "Committed"])
        var web = LaunchSpec(label: "web", kind: .codex, cwd: "/workspace/shop")
        web.createdAt = now.addingTimeInterval(-60)

        let lines = SessionStore.describeHistory([api, web], now: now).components(separatedBy: "\n")

        XCTAssertEqual(lines, [
            "@api [claude] /workspace/atlas (branch kuronami/api) · started 3 hours ago, closed 10 minutes ago · resumes its conversation",
            "    ended: Idle",
            "    summary: Added /orders. Tests pass.",
            "    task: Add an orders endpoint",
            "    - Ran tests",
            "    - Committed",
            "@web [codex] /workspace/shop · started 1 minute ago · starts fresh",
        ])
    }

    func testHistoryFiltersByFolderAndLeavesOutPastOrganizers() {
        let store = SessionStore(previewSessions: [], previewLayout: .grid)
        var organizer = LaunchSpec(label: "organizer", kind: .claude, cwd: "/workspace/atlas")
        organizer.organizer = true
        var renamed = LaunchSpec(label: "api", kind: .claude, cwd: "/workspace/atlas/server")
        renamed.previousLabels = ["bravo"]
        let other = LaunchSpec(label: "web", kind: .claude, cwd: "/workspace/atlas-web")
        store.recentlyClosed = [organizer, renamed, other]

        XCTAssertEqual(store.closedSessions().map(\.label), ["api", "web"])
        XCTAssertEqual(store.closedSessions(in: "/workspace/atlas/").map(\.label), ["api"])
        XCTAssertEqual(store.closedSession(named: "@Bravo")?.id, renamed.id)
        XCTAssertEqual(store.closedSession(named: other.id.uuidString)?.id, other.id)
        XCTAssertNil(store.closedSession(named: "organizer"))
    }

    private func agent(_ label: String, organizer: Bool = false, state: AgentState = .idle) -> TerminalSession {
        var spec = LaunchSpec(label: label, kind: .claude, cwd: "/workspace/atlas")
        if organizer { spec.organizer = true }
        let session = TerminalSession(spec: spec, resume: false)
        session.apply(.processStarted, source: "test", force: state)
        return session
    }
}
