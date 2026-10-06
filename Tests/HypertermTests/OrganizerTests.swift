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

    func testOrganizersBrowsersAreListedWithTheLooseOnes() {
        let api = agent("api"), organizer = agent("organizer", organizer: true)
        func browser(_ label: String, owner: TerminalSession?) -> TerminalSession {
            var spec = LaunchSpec(label: label, kind: .browser, cwd: "/workspace/atlas")
            spec.owner = owner?.id
            return TerminalSession(spec: spec, resume: false)
        }
        let mine = browser("docs", owner: api), its = browser("alpha", owner: organizer), loose = browser("web", owner: nil)
        let store = SessionStore(previewSessions: [api, organizer, mine, its, loose], previewLayout: .grid)

        XCTAssertEqual(store.browsers(ownedBy: api).map(\.id), [mine.id])
        XCTAssertEqual(store.looseBrowsers.map(\.id), [its.id, loose.id])
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
        store.flushOrganizerDigest(now: Date().addingTimeInterval(OrganizerDigest.window))

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

    func testWatchKeepsWhileTheOrganizerHasExited() {
        let api = agent("api", state: .idle), organizer = agent("organizer", organizer: true)
        let store = SessionStore(previewSessions: [api, organizer], previewLayout: .grid)
        organizer.apply(.childExited(0), source: "test")
        store.organizerWatches[api.id] = "next"

        store.reportToOrganizer(api, from: .working)

        XCTAssertTrue(store.organizerDigest.isEmpty)
        XCTAssertEqual(store.organizerWatches[api.id], "next")
    }

    func testAFinishedTurnIsMarkedDoneUntilLookedAtOrWorkResumes() {
        let api = agent("api", state: .working), web = agent("web", state: .idle)
        let store = SessionStore(previewSessions: [api, web], previewLayout: .grid)
        store.select(web)

        api.apply(.childExited(0), source: "test", force: .idle)
        store.sessionStateChanged(api, from: .working)
        XCTAssertTrue(api.finishedUnseen)
        XCTAssertFalse(web.finishedUnseen)

        store.select(api)
        XCTAssertFalse(api.finishedUnseen, "looking at it clears the mark")

        store.markFinished(web)
        XCTAssertTrue(web.finishedUnseen)
        web.apply(.childExited(0), source: "test", force: .working)
        XCTAssertFalse(web.finishedUnseen, "a new turn is not done")

        web.apply(.childExited(0), source: "test", force: .idle)
        web.runningSubagents = ["a1": Subagent(type: "Explore", startedAt: Date())]
        store.markFinished(web)
        XCTAssertFalse(web.finishedUnseen, "not done while a subagent still runs")
    }

    func testASelectedAgentIsMarkedDoneWhenOtherTerminalsAreOnScreen() {
        let api = agent("api", state: .idle), web = agent("web", state: .idle)
        let store = SessionStore(previewSessions: [api, web], previewLayout: .grid)
        store.select(web)

        store.markFinished(web)

        XCTAssertTrue(web.finishedUnseen, "two tiles are showing, so finishing is still worth marking")
    }

    func testMessagingAnAgentWatchesItForTheOrganizer() {
        let api = agent("api"), organizer = agent("organizer", organizer: true)
        let store = SessionStore(previewSessions: [api, organizer], previewLayout: .grid)
        var request = ControlRequest(cmd: .send)
        request.target = "api"
        request.text = "check the orders endpoint"

        ControlHandler(store: store, caller: .session(organizer.id.uuidString)).handle(request) { _ in }
        XCTAssertEqual(store.organizerWatches[api.id], "", "the reply will be reported")

        store.organizerWatches[api.id] = "then tell @web"
        ControlHandler(store: store, caller: .session(organizer.id.uuidString)).handle(request) { _ in }
        XCTAssertEqual(store.organizerWatches[api.id], "then tell @web", "an earlier note is kept")
    }

    func testBackgroundSubagentsHoldTheFinishUntilTheLastOneStops() {
        let api = agent("api", state: .idle), organizer = agent("organizer", organizer: true, state: .needsInput("busy"))
        let store = SessionStore(previewSessions: [api, organizer], previewLayout: .grid)
        store.organizerWatches[api.id] = "next"
        func hook(_ event: String, _ id: String) {
            store.applyHook(source: "claude", session: api, json: ["hook_event_name": event, "agent_id": id, "agent_type": "Explore"], sentAt: nil)
        }
        hook("SubagentStart", "a1")
        hook("SubagentStart", "a2")

        // The session's own turn ends while both still run.
        store.reportToOrganizer(api, from: .working)
        XCTAssertEqual(api.info().subagents, 2)
        XCTAssertEqual(api.runningSubagents["a1"]?.type, "Explore", "the sidebar names each one")
        hook("SubagentStop", "a1")
        hook("SubagentStop", "a1")
        store.flushOrganizerDigest(now: Date().addingTimeInterval(OrganizerDigest.window))
        XCTAssertTrue(organizer.pendingMessages.isEmpty)
        XCTAssertEqual(store.organizerWatches[api.id], "next")

        hook("SubagentStop", "a2")
        store.flushOrganizerDigest(now: Date().addingTimeInterval(OrganizerDigest.window))
        XCTAssertTrue((organizer.pendingMessages.first ?? "").contains("@api finished"), "\(organizer.pendingMessages)")
        XCTAssertNil(store.organizerWatches[api.id])
        XCTAssertNil(api.info().subagents)
    }

    func testEventsWaitForTheWindowAndArriveAsOneDigest() {
        let api = agent("api", state: .idle), db = agent("db", state: .failed("API error"))
        let organizer = agent("organizer", organizer: true, state: .needsInput("busy"))
        let store = SessionStore(previewSessions: [api, db, organizer], previewLayout: .grid)
        api.summary = "Added /orders."
        store.organizerWatches[api.id] = "tell @web"
        store.organizerWatches[db.id] = ""
        let start = Date()

        store.reportToOrganizer(api, from: .working)
        store.reportToOrganizer(db, from: .working)
        store.flushOrganizerDigest(now: start.addingTimeInterval(1))
        XCTAssertTrue(organizer.pendingMessages.isEmpty)

        store.flushOrganizerDigest(now: start.addingTimeInterval(OrganizerDigest.window + 1))
        XCTAssertEqual(organizer.pendingMessages,
                       ["Tako: 2 updates: [1] @api finished: Added /orders. (your note: tell @web) [2] @db failed: API error"])
        XCTAssertTrue(store.organizerDigest.isEmpty)
    }

    func testDigestWaitsWhileTheOrganizerIsMidTurn() {
        let api = agent("api", state: .exited(0)), organizer = agent("organizer", organizer: true, state: .working)
        let store = SessionStore(previewSessions: [api, organizer], previewLayout: .grid)
        store.organizerWatches[api.id] = "restart it"

        store.reportToOrganizer(api, from: .working)
        store.flushOrganizerDigest(now: Date().addingTimeInterval(OrganizerDigest.window + 1))

        XCTAssertTrue(organizer.pendingMessages.isEmpty)
        XCTAssertEqual(store.organizerDigest.events, [OrganizerEvent(label: "api", kind: .exited, note: "restart it")])
    }

    func testDigestWindowStartsAtTheFirstEvent() {
        var digest = OrganizerDigest()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(digest.isDue(at: start))
        digest.add(OrganizerEvent(label: "api", kind: .exited), at: start)
        digest.add(OrganizerEvent(label: "web", kind: .exited), at: start.addingTimeInterval(2))
        XCTAssertFalse(digest.isDue(at: start.addingTimeInterval(2)))
        XCTAssertTrue(digest.isDue(at: start.addingTimeInterval(OrganizerDigest.window)))

        let message = digest.take(cleared: true) ?? ""
        XCTAssertTrue(message.hasPrefix("Tako: Context was cleared. Read \(ControlPaths.organizerNotes)"), message)
        XCTAssertTrue(message.hasSuffix("[1] @api exited [2] @web exited"), message)
        XCTAssertNil(digest.take())
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

    // MARK: - Choosing its CLI

    /// Runs `body` with the organizer's choice kept in a throwaway suite, not the app's defaults.
    private func withOwnDefaults(_ body: (UserDefaults) -> Void) {
        let name = "OrganizerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let saved = SessionStore.organizerDefaults
        SessionStore.organizerDefaults = defaults
        defer { SessionStore.organizerDefaults = saved; defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    func testChooserShowsOnlyUntilACLIIsChosen() {
        withOwnDefaults { _ in
            let store = SessionStore(previewSessions: [], previewLayout: .grid)
            XCTAssertNil(SessionStore.chosenOrganizerKind)
            XCTAssertTrue(store.organizerNeedsChoice)

            SessionStore.organizerKind = .codex
            XCTAssertTrue(store.organizerNeedsChoice, "its model is asked next")

            SessionStore.setOrganizerModel("gpt-6-luna", for: .codex)
            XCTAssertFalse(store.organizerNeedsChoice)
        }
    }

    func testAModelIsAskedForEachCLIItHasntRunOn() {
        withOwnDefaults { _ in
            let store = SessionStore(previewSessions: [], previewLayout: .grid)
            SessionStore.organizerKind = .claude
            SessionStore.setOrganizerModel(nil, for: .claude)
            XCTAssertFalse(store.organizerNeedsChoice, "the CLI's default is a choice")
            XCTAssertNil(SessionStore.organizerModel(for: .claude), "and launches with no model flag")

            SessionStore.organizerKind = .codex
            XCTAssertTrue(store.organizerNeedsChoice)
        }
    }

    func testAModelSavedForAnotherCLIIsNeverLaunched() {
        withOwnDefaults { _ in
            // Codex's model saved under Claude, as an earlier mix-up left it.
            SessionStore.organizerDefaults.set("gpt-6-luna", forKey: "organizerModel.claude")
            XCTAssertNil(SessionStore.chosenOrganizerModel(for: .claude), "it is dropped, so the panel asks again")
            XCTAssertNil(SessionStore.organizerModel(for: .claude), "and Claude is launched with no model flag")
            XCTAssertNil(SessionStore.organizerDefaults.string(forKey: "organizerModel.claude"), "the bad value is cleaned up")

            XCTAssertTrue(SessionStore.isOrganizerModel("haiku", of: .claude))
            XCTAssertFalse(SessionStore.isOrganizerModel("haiku", of: .codex))
            XCTAssertTrue(SessionStore.isOrganizerModel("", of: .codex), "the CLI's own default fits every CLI")
        }
    }

    func testTheModelStepSavesForTheCLIItShowedNotTheCurrentOne() {
        withOwnDefaults { _ in
            let store = SessionStore(previewSessions: [], previewLayout: .grid)
            SessionStore.organizerKind = .claude
            store.chooseOrganizerModel("gpt-6-luna", for: .codex)
            XCTAssertEqual(SessionStore.organizerKind, .codex, "the CLI whose models were shown is the one chosen")
            XCTAssertEqual(SessionStore.chosenOrganizerModel(for: .codex), "gpt-6-luna")
            XCTAssertNil(SessionStore.chosenOrganizerModel(for: .claude), "nothing lands under the other CLI")

            store.chooseOrganizerModel("haiku", for: .codex)
            XCTAssertEqual(SessionStore.chosenOrganizerModel(for: .codex), "gpt-6-luna", "a model of another CLI is refused")
        }
    }

    func testEachCLIRecommendsItsSmallestModelFirst() {
        for kind in SessionStore.organizerChoices {
            let models = SessionStore.organizerModels(for: kind)
            XCTAssertEqual(models.filter(\.recommended).count, 1, "\(kind)")
            XCTAssertTrue(models.first?.recommended == true, "\(kind)")
            XCTAssertNotNil(models.first?.name.flatMap(AgentOptions.validModel), "\(kind)")
            XCTAssertTrue(models.contains { $0.name == nil }, "\(kind) offers its own default")
        }
        XCTAssertEqual(SessionStore.organizerModels(for: .claude).first?.name, "haiku")
    }

    func testAnOrganizerRunningFromBeforeTheChoiceCountsAsChosen() {
        withOwnDefaults { _ in
            let store = SessionStore(previewSessions: [agent("organizer", organizer: true)], previewLayout: .grid)
            XCTAssertNil(SessionStore.chosenOrganizerKind)
            XCTAssertFalse(store.organizerNeedsChoice)
        }
    }

    func testChoosingPersists() {
        withOwnDefaults { defaults in
            SessionStore.organizerKind = .codex
            XCTAssertEqual(defaults.string(forKey: SessionStore.organizerKindKey), "codex")
            XCTAssertEqual(SessionStore.chosenOrganizerKind, .codex)
            // Something that can't run it reads as not chosen.
            defaults.set("shell", forKey: SessionStore.organizerKindKey)
            XCTAssertNil(SessionStore.chosenOrganizerKind)
        }
    }

    func testOrganizerChoicesAreTheAgentKinds() {
        XCTAssertEqual(SessionStore.organizerChoices, SessionKind.allCases.filter(\.isAgent))
        XCTAssertTrue(SessionStore.organizerChoices.contains(.claude))
        XCTAssertFalse(SessionStore.organizerChoices.contains(.shell))
    }

    func testInstalledCLIsComeFromThePATHWithoutKuronamisWrappers() {
        let executables: Set<String> = ["/Users/me/.hyperterm/bin/claude", "/Users/me/.hyperterm/bin/codex", "/opt/homebrew/bin/codex"]
        let installed = InstalledAgents.installed([.claude, .codex], path: "/Users/me/.hyperterm/bin/:/usr/bin:/opt/homebrew/bin",
                                                  skipping: "/Users/me/.hyperterm/bin", isExecutable: executables.contains)
        XCTAssertEqual(installed, [.codex])
        XCTAssertEqual(InstalledAgents.installed([.claude, .codex], path: "", skipping: "/x", isExecutable: { _ in true }), [])
    }

    private func agent(_ label: String, organizer: Bool = false, state: AgentState = .idle) -> TerminalSession {
        var spec = LaunchSpec(label: label, kind: .claude, cwd: "/workspace/atlas")
        if organizer { spec.organizer = true }
        let session = TerminalSession(spec: spec, resume: false)
        session.apply(.processStarted, source: "test", force: state)
        return session
    }
}
