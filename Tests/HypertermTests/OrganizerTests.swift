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

    private func agent(_ label: String, organizer: Bool = false, state: AgentState = .idle) -> TerminalSession {
        var spec = LaunchSpec(label: label, kind: .claude, cwd: "/workspace/atlas")
        if organizer { spec.organizer = true }
        let session = TerminalSession(spec: spec, resume: false)
        session.apply(.processStarted, source: "test", force: state)
        return session
    }
}
