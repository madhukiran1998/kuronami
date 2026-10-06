import XCTest
@testable import Hyperterm

/// Idle agents sleeping and waking. Stores here are previews and sessions have no store, so
/// nothing is persisted and nothing relaunches.
@MainActor
final class SleepTests: XCTestCase {
    func testOnlyAnIdleAgentWithAConversationCanSleep() {
        let store = SessionStore(previewSessions: [], previewLayout: .grid)

        XCTAssertTrue(store.canSleep(agent("api")))
        for state in [AgentState.working, .starting, .needsInput("Bash: rm -rf build")] {
            XCTAssertFalse(store.canSleep(agent("busy", state: state)), "\(state)")
        }
        XCTAssertFalse(store.canSleep(agent("organizer", organizer: true)))
        XCTAssertFalse(store.canSleep(agent("fresh", summary: nil)), "no turn yet: nothing to resume")
        XCTAssertFalse(store.canSleep(agent("codex", kind: .codex)), "no thread id learned yet")
        let shell = track(TerminalSession(spec: LaunchSpec(label: "sh", kind: .shell, cwd: "/tmp"), resume: false))
        XCTAssertFalse(store.canSleep(shell))
    }

    func testAnAgentWithSubagentsRunningStaysAwake() {
        let store = SessionStore(previewSessions: [], previewLayout: .grid)
        let api = agent("api")
        api.runningSubagents = ["a1": Subagent(type: "Explore", startedAt: Date())]
        XCTAssertFalse(store.canSleep(api), "quitting would end its background subagent")
        api.apply(.processStarted, source: "test", force: .starting)
        XCTAssertTrue(api.runningSubagents.isEmpty, "a relaunched CLI has none")
    }

    func testAsleepAgentIgnoresItsExitAndReportsAsleep() {
        let session = agent("api")
        session.fallAsleep()

        XCTAssertTrue(session.isAsleep)
        XCTAssertEqual(session.spec.asleep, true)
        session.apply(.childExited(0), source: "process")
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.info().state, "asleep")
        XCTAssertEqual(session.info().asleep, true)
        XCTAssertEqual(session.statusWord, "Asleep")
        XCTAssertFalse(SessionStore(previewSessions: [], previewLayout: .grid).canSleep(session))
    }

    func testAsleepFlagPersistsAndRestoresAsleep() throws {
        var spec = LaunchSpec(label: "api", kind: .claude, cwd: "/tmp")
        spec.agentSessionId = UUID().uuidString.lowercased()
        spec.asleep = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LaunchSpec.self, from: encoder.encode(spec))
        XCTAssertEqual(decoded.asleep, true)

        let restored = track(TerminalSession(spec: decoded, resume: true))
        XCTAssertTrue(restored.isAsleep)
        XCTAssertEqual(restored.state, .idle)
        XCTAssertEqual(restored.spec.agentSessionId, spec.agentSessionId)
    }

    func testMessagesToAnAsleepAgentQueueUntilItWakes() {
        var spec = LaunchSpec(label: "api", kind: .claude, cwd: "/tmp")
        spec.asleep = true
        let session = track(TerminalSession(spec: spec, resume: true))

        let outcome = session.deliver("Message from @web: rebase please", from: "web")
        XCTAssertTrue(outcome.hasPrefix("queued"), outcome)
        XCTAssertEqual(session.pendingMessages, ["Message from @web: rebase please"])
        session.retryPendingMessages()
        XCTAssertEqual(session.pendingMessages.count, 1, "nothing is typed into the bare shell")
    }

    func testFreshClaudeGetsItsSessionIdUpFront() {
        let session = agent("api")
        XCTAssertNotNil(session.spec.agentSessionId.flatMap(UUID.init(uuidString:)))

        var spec = LaunchSpec(label: "api", kind: .claude, cwd: "/tmp")
        spec.agentSessionId = "0f8fad5b-d9cb-469f-a165-70867728950e"
        let fresh = AgentIntegration.initialInput(for: spec, resume: false) ?? ""
        XCTAssertTrue(fresh.contains("--session-id '0f8fad5b-d9cb-469f-a165-70867728950e'"), fresh)
        let saved = ClaudeAdapter.conversationExists
        defer { ClaudeAdapter.conversationExists = saved }
        ClaudeAdapter.conversationExists = { _, _ in true }
        let resumed = AgentIntegration.initialInput(for: spec, resume: true) ?? ""
        XCTAssertTrue(resumed.contains("--resume '0f8fad5b-d9cb-469f-a165-70867728950e'"))
        XCTAssertFalse(resumed.contains("--session-id"))
        // Quit before its first message (say at the folder-trust prompt): nothing to resume, so it
        // starts fresh under the same id rather than failing with "No conversation found".
        ClaudeAdapter.conversationExists = { _, _ in false }
        let neverSpoke = AgentIntegration.initialInput(for: spec, resume: true) ?? ""
        XCTAssertTrue(neverSpoke.contains("--session-id '0f8fad5b-d9cb-469f-a165-70867728950e'"), neverSpoke)
        XCTAssertFalse(neverSpoke.contains("--resume"))

        spec.agentSessionId = "not-a-uuid"
        XCTAssertFalse((AgentIntegration.initialInput(for: spec, resume: false) ?? "").contains("--session-id"))
        var fork = LaunchSpec(label: "fork", kind: .claude, cwd: "/tmp")
        fork.forkOf = "0f8fad5b-d9cb-469f-a165-70867728950e"
        XCTAssertNil(track(TerminalSession(spec: fork, resume: false)).spec.agentSessionId, "a fork learns its new id")
    }

    // MARK: - Fixtures

    private func agent(_ label: String, kind: SessionKind = .claude, organizer: Bool = false,
                       state: AgentState = .idle, summary: String? = "Fixed the login bug") -> TerminalSession {
        var spec = LaunchSpec(label: label, kind: kind, cwd: "/tmp")
        if organizer { spec.organizer = true }
        let session = track(TerminalSession(spec: spec, resume: false))
        session.summary = summary
        session.apply(.processStarted, source: "test", force: state)
        return session
    }

    /// Ends the session after the test, before its launch command would be typed.
    private func track(_ session: TerminalSession) -> TerminalSession {
        addTeardownBlock { @MainActor in session.terminate() }
        return session
    }
}
