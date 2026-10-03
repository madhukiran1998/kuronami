import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private var windowController: MainWindowController?
    private var controlServer: ControlServer?
    private let inspector = ProcessInspector()
    private let gitInspector = GitInspector()
    private var statusBar: StatusBarController?
    private var pollCount = 0
    private var lastRegistryStatus: [UUID: String] = [:]
    private var diffStatsInFlight = false
    private var gitInFlight = false

    private struct DiffTarget: Hashable, Sendable {
        let directory: String
        let base: String?
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // As a unit-test host, don't spawn terminals or take over the live control socket.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        if handOffToRunningInstance() { return }
        guard GhosttyRuntime.shared.start() else {
            let alert = NSAlert()
            alert.messageText = "Kuronami couldn't start the terminal engine"
            alert.informativeText = "libghostty failed to initialize. Check Console for messages from hyperterm."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        Theme.load(from: GhosttyRuntime.shared.config)
        TerminalSessionFactory.store = store
        AgentIntegration.install()
        NSApp.mainMenu = MainMenu.build(target: self)

        let controller = MainWindowController(store: store)
        windowController = controller
        controller.showWindow(nil)

        statusBar = StatusBarController(store: store)
        startControlServer()
        startInspector()
        store.notifier.onActivate = { [weak self] id in
            guard let self, let session = self.store.sessions.first(where: { $0.id == id }) else { return }
            self.store.select(session)
        }
        store.notifier.onApprovalAction = { [weak self] id, answer in
            guard let self, let session = self.store.sessions.first(where: { $0.id == id }) else { return }
            _ = self.store.answer(session, answer)
        }
        store.notifier.requestAuthorization()

        _ = store.restore()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard windowController != nil else { return .terminateNow }
        let busy = store.sessions.filter { $0.state == .working || $0.state.needsAttention }
        guard !busy.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Kuronami?"
        alert.informativeText = "\(busy.map { "@" + $0.label }.joined(separator: ", ")) \(busy.count == 1 ? "is" : "are") still working. Agent conversations resume the next time you open Kuronami."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard windowController != nil else { return }
        store.persist()
        controlServer?.stop()
        // Give the debounced persist a moment to land.
        Thread.sleep(forTimeInterval: 0.4)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.showWindow(nil)
        return true
    }

    /// One Kuronami owns the socket and the session list. A second copy (another build, a
    /// double launch) activates the first and quits instead of stealing them.
    private func handOffToRunningInstance() -> Bool {
        guard (try? sendControlRequest(ControlRequest(cmd: .list)))?.ok == true else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() }
        others.first?.activate()
        NSApp.terminate(nil)
        return true
    }

    private func startControlServer() {
        let store = self.store
        let inspector = self.inspector
        let server = ControlServer(path: ControlPaths.socketPath, identify: { inspector.identify(pid: $0) }) { request, caller, reply in
            ControlHandler(store: store, caller: caller).handle(request, reply: reply)
        }
        do {
            try server.start()
            controlServer = server
        } catch {
            NSLog("hyperterm: control socket failed: %@", String(describing: error))
        }
    }

    private func startInspector() {
        inspector.start(interval: Self.activePollInterval) { [weak self] snapshots in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(snapshots) }
            }
        }
        // In the background, ports and foreground commands go unseen and "needs you" arrives
        // through hooks, so the poll can halve its rate and save battery.
        let center = NotificationCenter.default
        let inspector = self.inspector
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            inspector.setInterval(Self.activePollInterval)
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            inspector.setInterval(Self.backgroundPollInterval)
        }
    }

    nonisolated private static let activePollInterval: TimeInterval = 2.5
    nonisolated private static let backgroundPollInterval: TimeInterval = 5

    private func apply(_ snapshots: [String: ProcessSnapshot]) {
        pollCount += 1
        refreshGit()
        // Working agents and the one on screen every ~10s; everything else once a minute (idle
        // agents also refresh on their Stop hook).
        if pollCount % 4 == 0 { refreshDiffStats(all: pollCount % 24 == 0) }
        for session in store.sessions {
            correctStaleWorking(session)
            session.retryPendingMessages()
            if session.kind.isAgent { trackAgentProcess(session, snapshots[session.id.uuidString]) }
            guard let snapshot = snapshots[session.id.uuidString] else { continue }
            if session.ports != snapshot.ports { session.ports = snapshot.ports }
            if session.foregroundProcess != snapshot.foreground { session.foregroundProcess = snapshot.foreground }
            if session.kind == .claude {
                if let status = snapshot.claudeStatus {
                    lastRegistryStatus[session.id] = status
                    session.apply(.registryStatus(status), source: "claude registry")
                }
            }
            if session.kind == .server, case .exited = session.state, snapshot.foreground != nil {
                session.apply(.processStarted, source: "process", force: .running)
            }
            if !session.kind.isAgent, session.state == .starting { session.apply(.processStarted, source: "process") }
        }
    }

    /// Claude fires no Stop hook when the user interrupts with Esc; the registry's "idle" then
    /// settles it once hooks have been quiet for a while.
    private func correctStaleWorking(_ session: TerminalSession) {
        guard session.kind == .claude, session.state == .working,
              Date().timeIntervalSince(session.lastHookAt) > 12,
              Date().timeIntervalSince(session.stateChangedAt) > 12 else { return }
        if lastRegistryStatus[session.id] == "idle" { session.apply(.processStarted, source: "claude registry", force: .idle) }
    }

    private func refreshDiffStats(all: Bool) {
        guard !diffStatsInFlight else { return }
        let agents = store.sessions.filter { session in
            session.kind.isAgent && (all || session.state == .working || session.id == store.selectedID)
        }
        guard !agents.isEmpty else { return }
        diffStatsInFlight = true
        let jobs = agents.map { ($0.id, DiffTarget(directory: $0.spec.workPath, base: $0.spec.baseBranch)) }
        let targets = Set(jobs.map { $0.1 })
        DispatchQueue.global(qos: .utility).async {
            let stats = Dictionary(uniqueKeysWithValues: targets.map {
                ($0, Review.diffStat(at: $0.directory, base: $0.base))
            })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.diffStatsInFlight = false
                    for (id, target) in jobs {
                        let stat = stats[target] ?? nil
                        guard let session = self.store.sessions.first(where: { $0.id == id }),
                              session.spec.workPath == target.directory, session.spec.baseBranch == target.base,
                              session.diffStat != stat else { continue }
                        session.diffStat = stat
                    }
                }
            }
        }
    }

    private func refreshGit() {
        guard !gitInFlight, !store.sessions.isEmpty else { return }
        gitInFlight = true
        let dirs = Dictionary(uniqueKeysWithValues: store.sessions.map { ($0.id, $0.spec.workPath) })
        let uniqueDirs = Set(dirs.values)
        let git = gitInspector
        DispatchQueue.global(qos: .utility).async {
            let infos = Dictionary(uniqueKeysWithValues: uniqueDirs.map { ($0, git.info(for: $0)) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.gitInFlight = false
                    for session in self.store.sessions {
                        guard dirs[session.id] == session.spec.workPath else { continue }
                        let info = infos[session.spec.workPath] ?? nil
                        if session.git != info { session.git = info }
                    }
                }
            }
        }
    }

    /// Agents run inside a shell, so "the agent quit" shows up as its process disappearing while
    /// the shell stays. Hooks report this for Claude; this covers Codex and crashes.
    private func trackAgentProcess(_ session: TerminalSession, _ snapshot: ProcessSnapshot?) {
        let name = session.kind == .claude ? "claude" : "codex"
        let alive = snapshot?.programs.contains { $0.contains(name) } ?? false
        if alive {
            session.agentProcessSeen = true
            if case .exited = session.state { session.apply(.processStarted, source: "process", force: .idle) }
        } else if session.agentProcessSeen || Date().timeIntervalSince(session.createdAt) > 20 {
            if case .exited = session.state { return }
            session.agentProcessSeen = false
            session.apply(.childExited(0), source: "process")
        }
    }

    // MARK: - Menu actions

    @objc func newSessionOfKind(_ sender: Any?) {
        guard let kind = (sender as? KindSender)?.kind else { return }
        if kind == .server { windowController?.presentNewSession(kind: .server) } else { windowController?.quickCreate(kind) }
    }

    @objc func find(_ sender: Any?) { windowController?.showSearch() }
    @objc func findNext(_ sender: Any?) { store.selected?.surface.performBinding("navigate_search:next") }
    @objc func findPrevious(_ sender: Any?) { store.selected?.surface.performBinding("navigate_search:previous") }
    @objc func openPreview(_ sender: Any?) {
        guard let port = (sender as? PortSender)?.port ?? store.selected?.ports.first else { NSSound.beep(); return }
        PreviewWindowController.show(port: port)
    }
    /// Channels only load servers from Claude's own MCP config, so turning this on registers
    /// Kuronami there with `claude mcp add --scope user` (and off removes it), after asking.
    @objc func toggleChannels(_ sender: NSMenuItem) {
        let enabling = !SessionStore.channelsEnabled
        let alert = NSAlert()
        alert.messageText = enabling ? "Deliver messages via Claude channels?" : "Stop using Claude channels?"
        alert.informativeText = enabling
            ? "Messages from other agents arrive in Claude as channel events instead of typed text. This registers Kuronami in your Claude config (claude mcp add --scope user hyperterm), and Claude asks you to confirm the development channel when each session starts. Applies to new or restarted sessions."
            : "Removes Kuronami from your Claude config (claude mcp remove --scope user hyperterm). Messages go back to being typed in."
        alert.addButton(withTitle: enabling ? "Turn On" : "Turn Off")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let command = enabling
            ? "claude mcp add --scope user hyperterm \(shellQuote(AgentIntegration.htPath)) mcp"
            : "claude mcp remove --scope user hyperterm"
        Task { @MainActor in
            let output = await Task.detached(priority: .userInitiated) {
                runProcess("/bin/zsh", ["-lic", command], timeout: 30)
            }.value
            if output == nil && enabling {
                let failure = NSAlert()
                failure.messageText = "Couldn't register Kuronami with Claude"
                failure.informativeText = "Running `\(command)` failed. Check that `claude` is on your PATH."
                failure.runModal()
                return
            }
            SessionStore.channelsEnabled = enabling
            sender.state = enabling ? .on : .off
        }
    }
    @objc func enableCodexApprovals(_ sender: Any?) { AgentIntegration.installCodexApprovalHook() }
    @objc func cleanUpWorktrees(_ sender: Any?) { windowController?.presentWorktreeCleanup() }
    @objc func toggleInspectorPane(_ sender: Any?) { windowController?.toggleInspector() }
    @objc func newBrowser(_ sender: Any?) { store.openBrowser() }
    @objc func minimizeTile(_ sender: Any?) {
        guard let session = store.selected else { NSSound.beep(); return }
        store.setMinimized(session, !session.isMinimized)
    }
    /// Agents use Kuronami's browsers by default; this also lets Claude agents use the
    /// user's own Chrome (Claude in Chrome). Applies to agents started afterwards.
    @objc func toggleOutsideChrome(_ sender: NSMenuItem) {
        AgentBrowser.agentsMayUseOutsideChrome.toggle()
        sender.state = AgentBrowser.agentsMayUseOutsideChrome ? .on : .off
        AgentIntegration.install()
    }
    @objc func reviewSelected(_ sender: Any?) {
        if let session = store.selected { windowController?.showInspector(for: session) }
    }
    @objc func showSwitcher(_ sender: Any?) { windowController?.toggleSwitcher() }
    @objc func layoutFocus(_ sender: Any?) { store.setLayout(.focus) }
    @objc func layoutSplit(_ sender: Any?) { store.setLayout(.split) }
    @objc func layoutGrid(_ sender: Any?) { store.setLayout(.grid) }
    @objc func toggleZoom(_ sender: Any?) { store.toggleZoom(store.selectedID) }

    @objc func newSession(_ sender: Any?) { windowController?.presentNewSession() }
    @objc func newShellHere(_ sender: Any?) { windowController?.quickCreate(.shell) }
    @objc func newClaudeHere(_ sender: Any?) { windowController?.quickCreate(.claude) }
    @objc func newCodexHere(_ sender: Any?) { windowController?.quickCreate(.codex) }

    @objc func closeSession(_ sender: Any?) {
        if let session = store.selected { windowController?.confirmClose(session) }
    }

    @objc func restartSession(_ sender: Any?) {
        if let session = store.selected { windowController?.confirmRestart(session) }
    }

    @objc func renameSession(_ sender: Any?) {
        if let session = store.selected { windowController?.presentRename(session) }
    }

    @objc func nextWaiting(_ sender: Any?) { store.selectNextNeedingAttention() }
    @objc func allowNext(_ sender: Any?) { answerNext(.approve) }
    @objc func denyNext(_ sender: Any?) { answerNext(.deny) }

    /// The focused agent if it's waiting, otherwise the one that has waited longest.
    private func answerNext(_ answer: PromptAnswer) {
        let waiting = store.sessions.filter { $0.state.needsAttention }.sorted { $0.stateChangedAt < $1.stateChangedAt }
        guard let target = store.selected.flatMap({ $0.state.needsAttention ? $0 : nil }) ?? waiting.first else { NSSound.beep(); return }
        if case .failure = store.answer(target, answer) { NSSound.beep(); store.select(target) }
    }
    @objc func nextSession(_ sender: Any?) { store.selectRelative(1) }
    @objc func previousSession(_ sender: Any?) { store.selectRelative(-1) }

    @objc func selectSessionByIndex(_ sender: NSMenuItem) { store.select(index: sender.tag) }

    @objc func installCLI(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Use ht from any terminal"
        alert.informativeText = "Add this line to your ~/.zshrc:\n\nexport PATH=\"$HOME/.hyperterm/bin:$PATH\"\n\nThen run `ht ls` to list terminals or `ht send @api \"…\"` to message one. The Claude and Codex wrappers in that folder add Kuronami's hooks automatically."
        alert.addButton(withTitle: "Copy Line")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("export PATH=\"$HOME/.hyperterm/bin:$PATH\"", forType: .string)
        }
    }
}
