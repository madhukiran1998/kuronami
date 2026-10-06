import XCTest
@testable import Hyperterm

/// Phone Mode: every agent's waits go to the organizer, ordinary requests are allowed by the app,
/// and risky ones need the user's yes from their phone. Preview stores post no banners.
@MainActor
final class PhoneModeTests: XCTestCase {
    func testTurningOnHandsEveryAgentToTheOrganizerAndOffHandsThemBack() {
        let (store, api, organizer) = fixture(extra: "web")
        let web = store.sessions.first { $0.label == "web" }!
        _ = store.delegate(web, scope: .count(3), note: "prefer pnpm")

        store.setPhoneMode(true)
        XCTAssertEqual(api.delegation?.scope, .phoneMode)
        XCTAssertEqual(api.delegation?.shortScope, "phone")
        XCTAssertEqual(web.delegation?.scope, .count(3), "a scope the user chose stays")
        XCTAssertNil(organizer.delegation)
        XCTAssertEqual(store.organizerDigest.events.first?.kind, .phoneMode(true))

        store.setPhoneMode(false)
        XCTAssertNil(api.delegation)
        XCTAssertEqual(web.delegation?.scope, .count(3))
        XCTAssertNil(store.phoneModeSince)
        XCTAssertEqual(store.organizerDigest.events.last?.kind, .phoneMode(false))
    }

    func testStartingWithTheOrganizerUpOpensRemoteControlAtOnce() {
        let (store, _, organizer) = fixture()
        store.startPhoneMode()
        XCTAssertTrue(store.isPhoneModeOn)
        XCTAssertFalse(store.remoteControlWhenOrganizerUp)
        XCTAssertEqual(organizer.pendingMessages.last, "/remote-control")
    }

    func testPhoneModeScopeNeverRunsOut() {
        var delegation = Delegation(scope: .phoneMode)
        delegation.handled = 500
        XCTAssertFalse(delegation.isUsedUp(at: .distantFuture))
        XCTAssertEqual(delegation.scopePhrase, "while Phone Mode is on")
    }

    func testAgentsStartedWhileOnAreAdopted() {
        let (store, _, _) = fixture()
        store.setPhoneMode(true)
        let late = agent("late")
        XCTAssertTrue(store.adoptIntoPhoneMode(late))
        XCTAssertEqual(late.delegation?.scope, .phoneMode)
        XCTAssertFalse(store.adoptIntoPhoneMode(late), "adopted once")
    }

    func testOrdinaryRequestsAreAllowedWithoutWaiting() {
        let (store, api, _) = fixture()
        store.setPhoneMode(true)
        var answered: String?
        store.registerApproval(for: api, source: "claude", payload: request("pnpm test")) { answered = $0.text }

        XCTAssertTrue(answered?.contains("\"allow\"") == true)
        XCTAssertFalse(api.hasHookApproval)
        XCTAssertFalse(api.state.needsAttention)
    }

    func testRiskyRequestsWaitForTheUsersYesFromTheirPhone() {
        let (store, api, _) = fixture()
        store.setPhoneMode(true)
        var answered: String?
        store.registerApproval(for: api, source: "claude", payload: request("rm -rf build")) { answered = $0.text }
        XCTAssertNil(answered, "risky: held for the organizer and the user")
        XCTAssertTrue(api.hasHookApproval)

        guard case .failure(let refused) = store.answerForOrganizer(api, .approve, reason: nil) else {
            return XCTFail("approved a risky request without the user's yes")
        }
        XCTAssertTrue(refused.description.contains("ask the user on their phone"))
        XCTAssertTrue(api.hasHookApproval, "still waiting, not escalated away")

        guard case .success = store.answerForOrganizer(api, .approve, reason: nil, userApproved: true) else {
            return XCTFail("the user's yes should approve it")
        }
        XCTAssertTrue(answered?.contains("\"allow\"") == true)
    }

    func testUserApprovedMeansNothingOutsidePhoneMode() {
        let (store, api, _) = fixture()
        _ = store.delegate(api, scope: .turn, note: nil)
        store.registerApproval(for: api, source: "claude", payload: request("rm -rf build")) { _ in }

        guard case .failure(let refused) = store.answerForOrganizer(api, .approve, reason: nil, userApproved: true) else {
            return XCTFail("risky requests outside Phone Mode are the user's")
        }
        XCTAssertTrue(refused.description.hasPrefix("left for the user"))
    }

    func testNothingIsAllowedAutomaticallyWhenOff() {
        let (store, api, _) = fixture()
        var answered: String?
        store.registerApproval(for: api, source: "claude", payload: request("pnpm test")) { answered = $0.text }
        XCTAssertNil(answered)
        XCTAssertTrue(api.hasHookApproval)
    }

    // MARK: - Fixtures

    private func fixture(extra: String? = nil) -> (SessionStore, TerminalSession, TerminalSession) {
        let api = agent("api"), organizer = agent("organizer", organizer: true)
        organizer.apply(.processStarted, source: "test", force: .working)
        let store = SessionStore(previewSessions: [api, organizer] + (extra.map { [agent($0)] } ?? []), previewLayout: .grid)
        api.store = store
        return (store, api, organizer)
    }

    private func agent(_ label: String, organizer: Bool = false) -> TerminalSession {
        var spec = LaunchSpec(label: label, kind: .claude, cwd: "/workspace/atlas")
        if organizer { spec.organizer = true }
        let session = TerminalSession(spec: spec, resume: false)
        session.apply(.processStarted, source: "test", force: .idle)
        return session
    }

    private func request(_ command: String) -> String {
        let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": command], "cwd": "/workspace/atlas"]
        return String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }
}
