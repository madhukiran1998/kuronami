import AppKit

/// Maps control requests to store operations and enforces who may do what.
///
/// The caller comes from the kernel (`CallerIdentity`), never from the request. Fail closed:
/// - The user is a process outside Tako, or one traced to a shell/server terminal.
/// - Agents (traced to an agent terminal) may message other agents, read agents and servers,
///   restart servers, start servers with the user's OK, and rename only themselves.
/// - Anything else from inside Tako (detached, unknown) gets read-only access.
/// Only the user may press keys, answer prompts, close terminals, or type raw text: those would
/// let one agent answer another's permission prompts or run commands outside its own checks.
/// The organizer (the agent behind the sidebar's box) also starts agents in any folder, arranges
/// the view, and closes terminals once the user confirms. It answers permission prompts only
/// for sessions the user handed it, never "always", and never past the risky-request guard.
@MainActor
struct ControlHandler {
    let store: SessionStore
    let caller: CallerIdentity

    private var callerSession: TerminalSession? {
        guard case .session(let id) = caller else { return nil }
        return store.session(forEnvironmentID: id)
    }

    private var callerAgent: TerminalSession? {
        guard let session = callerSession, session.kind.isAgent else { return nil }
        return session
    }

    private var callerOrganizer: TerminalSession? {
        guard let agent = callerAgent, agent.isOrganizer else { return nil }
        return agent
    }

    private var isUser: Bool {
        switch caller {
        case .external: return true
        case .session: return callerSession.map { !$0.kind.isAgent } ?? false
        case .detachedInside, .unknown: return false
        }
    }

    /// An agent's browser tools ask this before acting: Chromium is started, the caller's own
    /// browser exists (created on first use), and every page is tagged with its session label so
    /// the tools can tell browsers apart. Replies with the caller's browser label.
    private func handleBrowser(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        guard callerSession != nil || isUser else { reply(.failure("not allowed from here")); return }
        guard AgentBrowser.shared.start() else {
            reply(.failure("browser unavailable: \(AgentBrowser.shared.startError ?? "Chromium didn't start")"))
            return
        }
        let target: TerminalSession
        if let agent = callerAgent {
            target = store.browser(for: agent)
        } else if let selected = store.selected, selected.kind == .browser {
            target = selected
        } else {
            target = store.looseBrowsers.first ?? store.openBrowser()
        }
        if let tool = request.text, tool != "mark", let agent = callerAgent {
            AgentBrowser.shared.noteActivity(agent: agent.label, browser: target.label, tool: tool)
        }
        store.wakeBrowser(target)
        let store = self.store
        AgentBrowser.waitUntilReady({ store.isBrowserReady(target) }) { ready in
            guard ready else { reply(.failure("browser unavailable: Chromium didn't come up")); return }
            store.markBrowsers()
            // Tags land asynchronously in each page's renderer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                var response = ControlResponse.success(text: target.label)
                response.endpoint = AgentBrowser.endpoint
                reply(response)
            }
        }
    }

    func handle(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        switch request.cmd {
        case .permission:
            handlePermission(request, reply: reply)
        case .browser:
            handleBrowser(request, reply: reply)
        case .subscribe:
            guard let agent = callerAgent, agent.kind == .claude else { reply(.success()); return }
            store.subscribeChannel(agent, reply: reply)
        case .new where callerOrganizer != nil && (request.kind == SessionKind.claude.rawValue || request.kind == SessionKind.codex.rawValue):
            startAgentForOrganizer(request, reply: reply)
        case .close where callerOrganizer != nil:
            closeForOrganizer(request, reply: reply)
        case .new where callerAgent != nil && request.kind == SessionKind.server.rawValue:
            startServerForAgent(request, reply: reply)
        case .new where callerAgent != nil && (request.kind == SessionKind.claude.rawValue || request.kind == SessionKind.codex.rawValue):
            startAgentForAgent(request, reply: reply)
        default:
            reply(handle(request))
        }
    }

    private func handle(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .list:
            var response = ControlResponse.success()
            response.sessions = store.orderedSessions.map { $0.info() }
            return response
        case .hook:
            // Hook events only count when the kernel traces them to the session they describe.
            guard let session = callerSession else { return .success() }
            store.handleHook(source: request.source ?? "", session: session, payload: request.payload ?? "{}", sentAt: request.sentAt)
            return .success()
        case .statusline:
            guard let session = callerSession else { return .success() }
            store.handleStatusLine(session: session, payload: request.payload ?? "{}")
            return .success()
        case .key:
            guard isUser else { return .failure("only the user can press keys in terminals") }
            guard let target = resolve(request.target) else { return notFound(request.target) }
            let unknown = (request.keys ?? []).filter { !target.surface.pressKey(named: $0) }
            return unknown.isEmpty ? .success() : .failure("unknown key names: \(unknown.joined(separator: ", "))")
        case .layout:
            guard isUser else { return .failure("only the user can change the layout") }
            guard let mode = LayoutMode(rawValue: request.text ?? "") else { return .failure("layout must be focus, split, or grid") }
            store.setLayout(mode)
            return .success()
        case .new:
            return create(request)
        case .status:
            let target = callerAgent ?? (isUser ? resolve(request.target) : nil)
            guard let me = target else { return .failure("set_status works from inside an agent terminal") }
            let text = sanitizeMessage(request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            me.agentStatus = text.isEmpty ? nil : String(text.prefix(140))
            return .success(text: "status set on @\(me.label)")
        case .approve where callerOrganizer != nil:
            return answerForOrganizer(request)
        case .approve:
            guard isUser else { return .failure("only the user can answer prompts") }
            guard let target = resolve(request.target) else { return notFound(request.target) }
            guard let answer = PromptAnswer(rawValue: request.text ?? "") else {
                return .failure("answer must be approve, always, or deny")
            }
            switch store.answer(target, answer, reason: request.label) {
            case .success(let text): return .success(text: "\(text) @\(target.label)")
            case .failure(let error): return .failure(error.description)
            }
        case .send:
            return send(request)
        case .read:
            return read(request)
        case .focus:
            guard isUser else { return .failure("only the user can change focus") }
            guard let target = resolve(request.target) else { return notFound(request.target) }
            store.select(target)
            NSApp.activate(ignoringOtherApps: true)
            return .success()
        case .close:
            guard isUser else { return .failure("only the user can close terminals") }
            guard let target = resolve(request.target) else { return notFound(request.target) }
            store.close(target)
            return .success()
        case .restart:
            return restart(request)
        case .arrange:
            guard callerOrganizer != nil else { return .failure("only the organizer arranges the view") }
            return arrange(request)
        case .layouts:
            guard callerOrganizer != nil else { return .failure("only the organizer keeps layouts") }
            return layouts(request)
        case .watch:
            guard callerOrganizer != nil else { return .failure("only the organizer watches terminals") }
            return watch(request)
        case .history:
            guard callerOrganizer != nil else { return .failure("only the organizer reopens past sessions") }
            return history(request)
        case .machine:
            guard callerOrganizer != nil else { return .failure("only the organizer reads the steward") }
            return machine(request)
        case .detach:
            guard callerOrganizer != nil || isUser else { return .failure("only the organizer moves tiles into windows") }
            return detach(request)
        case .delegate:
            // Only the organizer takes sessions over (when the user asks it to); the user may also stop or list.
            guard callerOrganizer != nil || (isUser && request.text != "handle") else {
                return .failure("only the organizer handles waiting sessions, when the user asks")
            }
            return delegate(request)
        case .rename:
            return rename(request)
        case .notify:
            guard let target = callerSession ?? (isUser ? resolve(request.target) : nil) else { return notFound(request.target) }
            store.sessionWantsAttention(target, title: "@\(target.label)", body: sanitizeMessage(request.text ?? ""))
            return .success()
        case .permission, .subscribe, .browser, .heavy:
            return .success()
        }
    }

    private func resolve(_ target: String?) -> TerminalSession? {
        guard let target, !target.isEmpty else { return nil }
        return store.find(target)
    }

    private func notFound(_ target: String?) -> ControlResponse {
        let known = store.sessions.map { "@" + $0.label }.joined(separator: ", ")
        return .failure("no terminal named \(target ?? "(none)"). Known: \(known.isEmpty ? "none" : known)")
    }

    // MARK: - Commands

    private func create(_ request: ControlRequest) -> ControlResponse {
        guard let kind = SessionKind(rawValue: request.kind ?? "shell") else {
            return .failure("kind must be one of: claude, codex, shell, server")
        }
        if !isUser {
            guard callerAgent != nil else { return .failure("not allowed from a detached process") }
            if kind == .shell { return .failure("agents can't open shells; ask the user") }
            // Raw flags would let an agent start a sibling with weaker permissions.
            if request.command?.isEmpty == false { return .failure("agents can't pass extra arguments to new agents") }
        }
        let cwd = request.cwd ?? callerSession?.spec.cwd ?? NSHomeDirectory()
        var spec = LaunchSpec(label: request.label ?? "", kind: kind, cwd: cwd, command: request.command)
        if callerAgent != nil && spec.labelSource == .user { spec.labelSource = .agent }
        if let account = request.account {
            guard AccountStore.shared.account(account, kind: kind) != nil else {
                return .failure("no \(kind.displayName) account named \(account); add it in Accounts")
            }
            if account != AgentAccount.defaultID { spec.account = account }
        } else if let parent = callerAgent, parent.kind == kind {
            // An agent's helpers bill the same subscription it does.
            spec.account = parent.spec.account
        }
        let session = store.create(spec, select: isUser, worktree: request.worktree ?? false, task: request.text)
        var response = ControlResponse.success(text: "@\(session.label)")
        response.session = session.info()
        return response
    }

    /// A command an agent wants run as a server runs outside its own permission checks, so the
    /// user confirms it in the app first.
    private func startServerForAgent(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        guard let agent = callerAgent, let command = request.command, !command.isEmpty else {
            reply(.failure("a server needs a command"))
            return
        }
        // An agent CLI run as a server gets none of Tako's hooks: no state, no messages, no sleep.
        let program = (command.split(separator: " ").first.map(String.init) ?? "") as NSString
        if SessionKind.agentAdapters.contains(where: { $0.command == program.lastPathComponent }) {
            reply(.failure("that's an agent, not a server: resume a conversation with reopen_session (conversation, folder), or start one with start_agent"))
            return
        }
        let label = normalizeLabel(request.label ?? "")
        let cwd = request.cwd ?? agent.spec.cwd
        store.confirm(
            "@\(agent.label) wants to start a server",
            "\(label.isEmpty ? "" : "@\(label) · ")\(abbreviateHome(cwd))\n\n\(command)"
        ) { approved in
            guard approved else {
                reply(.failure("the user declined to start that server"))
                return
            }
            var spec = LaunchSpec(label: label, kind: .server, cwd: cwd, command: command)
            if spec.labelSource == .user { spec.labelSource = .agent }
            let session = store.create(spec, select: false)
            var response = ControlResponse.success(text: "started @\(session.label)")
            response.session = session.info()
            reply(response)
        }
    }

    /// An agent delegating a subtask. Each new agent costs usage and works outside its parent's
    /// view, so the user confirms it. The child inherits the parent's account and permission
    /// choices (never more), gets its own worktree by default, and is asked to report back.
    private func startAgentForAgent(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        guard let parent = callerAgent, let kind = SessionKind(rawValue: request.kind ?? ""), kind.isAgent else {
            reply(.failure("kind must be claude or codex"))
            return
        }
        if request.command?.isEmpty == false {
            reply(.failure("agents can't pass extra arguments to new agents"))
            return
        }
        let task = sanitizeMessage(request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            reply(.failure("a new agent needs a task"))
            return
        }
        let cwd = request.cwd ?? parent.spec.workPath
        let worktree = request.worktree ?? true
        store.confirm(
            "@\(parent.label) wants to start a \(kind.displayName) agent",
            "\(abbreviateHome(cwd))\(worktree ? " · own worktree" : "")\n\n\(task)"
        ) { [store] approved in
            guard approved else {
                reply(.failure("the user declined to start that agent"))
                return
            }
            var spec = LaunchSpec(label: request.label ?? "", kind: kind, cwd: cwd)
            if spec.labelSource == .user { spec.labelSource = .agent }
            if parent.kind == kind {
                spec.account = parent.spec.account
                spec.options = parent.spec.options
            }
            let brief = task + "\n\n(Delegated by @\(parent.label) through Tako. When you finish, use send_message to tell @\(parent.label) what you did and where.)"
            Task { @MainActor [spec] in
                let child = await store.launch(spec, select: false, worktree: worktree, task: brief)
                child.record(.note, "Started by @\(parent.label)")
                parent.record(.note, "Delegated to @\(child.label)")
                var response = ControlResponse.success(text: "started @\(child.label); it will message you when done")
                response.session = child.info()
                reply(response)
            }
        }
    }

    // MARK: - Organizer

    /// The user asked the organizer for these agents, so they start without a second prompt, in
    /// whatever folder it names, isolated in a worktree where the folder is a repo.
    private func startAgentForOrganizer(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        guard let kind = SessionKind(rawValue: request.kind ?? ""), kind.isAgent else {
            reply(.failure("kind must be claude or codex"))
            return
        }
        if request.command?.isEmpty == false {
            reply(.failure("agents can't pass extra arguments to new agents"))
            return
        }
        let task = sanitizeMessage(request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            reply(.failure("a new agent needs a task"))
            return
        }
        guard let folder = request.cwd, !folder.isEmpty else {
            reply(.failure("say which project folder the agent works in"))
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandTilde(folder), isDirectory: &isDirectory), isDirectory.boolValue else {
            reply(.failure("no folder at \(folder)"))
            return
        }
        let count = request.count ?? 1
        guard (1...organizerStartCap).contains(count) else {
            reply(.failure("count must be 1–\(organizerStartCap)"))
            return
        }
        let base = normalizeLabel(request.label ?? "")
        let isolate = request.worktree ?? true
        let store = self.store
        // When memory is short the steward holds the launch; the organizer hears so right away.
        let blocker = Steward.shared.launchBlocker()
        let queued = blocker != nil
        if let blocker {
            reply(.success(text: "queued: \(blocker), so the steward starts \(count == 1 ? "it" : "them") when there's room"))
        }
        Steward.shared.enqueueLaunch { Task { @MainActor in
            var started: [TerminalSession] = []
            for index in 1...count {
                var spec = LaunchSpec(label: base.isEmpty || count == 1 ? base : "\(base)-\(index)",
                                      kind: kind, cwd: expandTilde(folder))
                if spec.labelSource == .user { spec.labelSource = .agent }
                spec.options = AppSettings.defaultMode.map { AgentOptions(mode: $0) }
                let child = await store.launch(spec, select: false, isolateIfPossible: isolate, task: task)
                child.record(.note, "Started by the organizer")
                started.append(child)
            }
            // The user asked for them, so they show: one is selected, several land side by side
            // like a project window opened for them.
            store.showOpenedByOrganizer(started)
            let labels = started.map { "@" + $0.label }.joined(separator: ", ")
            guard !queued else { return }
            var response = ControlResponse.success(text: "started \(labels) in \(abbreviateHome(expandTilde(folder)))")
            response.session = started.first?.info()
            reply(response)
        } }
    }

    /// Closed agents: list them, or reopen some and show them, resuming each conversation.
    private func history(_ request: ControlRequest) -> ControlResponse {
        switch request.text {
        case "list":
            let closed = store.closedSessions(in: request.cwd)
            guard !closed.isEmpty else {
                let place = request.cwd.map { " in " + abbreviateHome(expandTilde($0)) } ?? ""
                return .success(text: "No recently closed sessions\(place).")
            }
            let shown = Array(closed.prefix(max(request.lines ?? 15, 1)))
            return .success(text: "Recently closed, newest first:\n" + SessionStore.describeHistory(shown))
        case "reopen":
            let names = request.targets ?? request.target.map { [$0] } ?? []
            guard !names.isEmpty else { return .failure("say which session to reopen") }
            // An unknown name reopens nothing, so a retry doesn't open the rest twice.
            var specs: [LaunchSpec] = []
            for name in names {
                guard let spec = store.closedSession(named: name) else {
                    let known = store.closedSessions().map { "@" + $0.label }.joined(separator: ", ")
                    return .failure("no closed session named \(name). Closed: \(known.isEmpty ? "none" : known)")
                }
                if !specs.contains(where: { $0.id == spec.id }) { specs.append(spec) }
            }
            var reopened: [TerminalSession] = []
            var lines: [String] = []
            for spec in specs {
                guard let session = store.reopen(spec) else {
                    lines.append(store.lastError ?? "@\(spec.label) couldn't be reopened")
                    continue
                }
                reopened.append(session)
                let renamed = session.label == spec.label ? "" : " (was @\(spec.label))"
                lines.append("@\(session.label)\(renamed) " + (spec.agentSessionId == nil ? "started fresh" : "resumed its conversation"))
            }
            store.showOpenedByOrganizer(reopened)
            let text = lines.joined(separator: "\n")
            guard !reopened.isEmpty else { return .failure(text) }
            var response = ControlResponse.success(text: text)
            response.session = reopened.first?.info()
            return response
        case "resume":
            return resumeConversation(request)
        default:
            return .failure("history takes list, reopen or resume")
        }
    }

    /// A Claude or Codex conversation Tako never ran (say from the CLI on its own), resumed as
    /// a proper agent: hooks, state, sleep and messages all work, unlike a bare process.
    private func resumeConversation(_ request: ControlRequest) -> ControlResponse {
        guard let kind = SessionKind(rawValue: request.kind ?? "claude"), kind.isAgent else {
            return .failure("kind must be claude or codex")
        }
        guard let id = request.target, isSafeIdentifier(id) else { return .failure("give the conversation id") }
        if let open = store.sessions.first(where: { $0.spec.agentSessionId == id }) {
            store.select(open)
            return .success(text: "@\(open.label) already has that conversation open; it's on screen")
        }
        guard let folder = request.cwd.map(expandTilde), !folder.isEmpty else {
            return .failure("say which folder the conversation ran in")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure("no folder at \(folder)")
        }
        var spec = LaunchSpec(label: normalizeLabel(request.label ?? ""), kind: kind, cwd: folder)
        if spec.labelSource == .user { spec.labelSource = .agent }
        spec.agentSessionId = id
        spec.options = AppSettings.defaultMode.map { AgentOptions(mode: $0) }
        let session = store.create(spec, resume: true, select: false)
        session.record(.note, "Resumed by the organizer")
        store.showOpenedByOrganizer([session])
        var response = ControlResponse.success(text: "resumed @\(session.label) in \(abbreviateHome(folder))")
        response.session = session.info()
        return response
    }

    /// Pops terminals out of the canvas into their own windows, or puts them back.
    private func detach(_ request: ControlRequest) -> ControlResponse {
        let back = request.text == "back"
        let names = request.targets ?? request.target.map { [$0] } ?? []
        guard !names.isEmpty else { return .failure("say which terminals") }
        var moved: [String] = []
        for name in names {
            guard let session = resolve(name) else { return notFound(name) }
            guard !session.isOrganizer else { return .failure("the organizer has its own panel") }
            if back {
                guard session.isDetached else { continue }
                store.onReattach?(session)
            } else {
                guard !session.isDetached else { continue }
                store.wake(session)
                store.onDetach?(session)
            }
            moved.append("@" + session.label)
        }
        guard !moved.isEmpty else { return .success(text: back ? "already in the canvas" : "already in their own windows") }
        return .success(text: (back ? "put back in the canvas: " : "in their own windows: ") + moved.joined(separator: ", "))
    }

    /// The steward's view of the machine, or a change to its policy.
    private func machine(_ request: ControlRequest) -> ControlResponse {
        let steward = Steward.shared
        if request.text == "policy" {
            var policy = steward.policy
            if let cap = request.count { policy.maxActiveAgents = cap > 0 ? cap : nil }
            if let pinned = request.targets { policy.pinned = Set(pinned.map(normalizeLabel).filter { !$0.isEmpty }) }
            steward.policy = policy
            let cap = policy.maxActiveAgents.map { "at most \($0) agents at once" } ?? "no agent cap"
            let pinned = policy.pinned.isEmpty ? "nothing pinned" : "pinned " + policy.pinned.sorted().map { "@" + $0 }.joined(separator: ", ")
            return .success(text: "Policy: \(cap), \(pinned).")
        }
        return .success(text: Self.describe(steward.status()))
    }

    static func describe(_ status: MachineStatus) -> String {
        func gb(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
        let power = status.lowPower ? ", Low Power Mode" : ""
        var lines = ["Memory pressure \(status.pressure.rawValue), heat \(status.thermal.rawValue)\(power); \(gb(status.freeBytes)) free of \(gb(status.totalBytes))."]
        let queued = status.queuedLaunches > 0 ? ", \(status.queuedLaunches) queued" : ""
        let waiting = status.heavyWaiting > 0 ? ", \(status.heavyWaiting) waiting" : ""
        lines.append("New agents \(status.admissionOK ? "can start now" : "wait for memory")\(queued). Heavy jobs: \(status.heavySlotsUsed)/\(status.heavySlotsTotal) slots\(waiting).")
        for session in status.sessions.sorted(by: { $0.footprintBytes > $1.footprintBytes }) {
            var line = "@\(session.label) \(session.band.rawValue) · \(gb(session.footprintBytes))"
            if let cpu = session.cpuPercent { line += String(format: " · %.0f%% CPU", cpu) }
            if session.lowered { line += " · lowered" }
            if let warning = session.escalation { line += " · warning: " + warning.message }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Named layouts: save the window as it is, put one back, or list them.
    private func layouts(_ request: ControlRequest) -> ControlResponse {
        let name = (request.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch request.text {
        case "save":
            guard !name.isEmpty else { return .failure("give the layout a name") }
            store.saveLayout(name)
            return .success(text: "saved \"\(name)\"")
        case "restore":
            guard store.savedLayouts[name] != nil else {
                let known = store.savedLayouts.keys.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
                return .failure("no layout named \"\(name)\". Saved: \(known.isEmpty ? "none" : known)")
            }
            guard let shown = store.restoreLayout(name) else { return .failure("every terminal in \"\(name)\" has been closed") }
            return .success(text: "restored \"\(name)\"" + (shown.isEmpty ? "" : ": " + shown.map { "@" + $0 }.joined(separator: ", ")))
        default:
            let all = store.savedLayouts
            guard !all.isEmpty else { return .success(text: "No saved layouts.") }
            return .success(text: all.keys.sorted().map { name in
                let saved = all[name]!
                return "\"\(name)\": \(saved.layout.rawValue)" + (saved.focus.map { ", focus @\($0)" } ?? "")
            }.joined(separator: "\n"))
        }
    }

    /// One report per watch: the organizer hears when the terminal ends its next turn.
    private func watch(_ request: ControlRequest) -> ControlResponse {
        guard let target = resolve(request.target) else { return notFound(request.target) }
        guard target.kind.isAgent, !target.isOrganizer else { return .failure("only other agents can be watched") }
        let note = sanitizeMessage(request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        store.organizerWatches[target.id] = String(note.prefix(1000))
        return .success(text: "you'll get a message when @\(target.label) finishes its turn")
    }

    /// The user handed a session's waits to the organizer: take them over, stop, or list.
    private func delegate(_ request: ControlRequest) -> ControlResponse {
        if request.text == "list" {
            let handled = store.sessions.compactMap { session in
                session.delegation.map { "@\(session.label): \($0.scopePhrase)" + ($0.note.map { " (note: \($0))" } ?? "") }
            }
            return .success(text: handled.isEmpty ? "No sessions are handed to the organizer." : handled.joined(separator: "\n"))
        }
        guard let target = resolve(request.target) else { return notFound(request.target) }
        switch request.text {
        case "handle":
            guard target.kind.isAgent, !target.isOrganizer else { return .failure("only other agents' waits can be handed over") }
            let scope: Delegation.Scope
            switch request.label {
            case "turn":
                scope = .turn
            case "count":
                guard let count = request.count, (1...50).contains(count) else { return .failure("count must be 1–50") }
                scope = .count(count)
            case "minutes":
                guard let minutes = request.count, (1...1440).contains(minutes) else { return .failure("minutes must be 1–1440") }
                scope = .until(Date().addingTimeInterval(TimeInterval(minutes * 60)))
            default:
                return .failure("scope must be turn, count, or minutes")
            }
            let note = String(sanitizeMessage(request.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
            let waiting = store.delegate(target, scope: scope, note: note.isEmpty ? nil : note)
            var text = "handling @\(target.label)'s waits \(target.delegation?.scopePhrase ?? ""). Tako messages you when it waits; "
                + "the user is notified if you don't answer within \(Int(Delegation.fallback)) s."
            if let waiting { text += " It is waiting now: \(waiting). read_terminal it, then answer." }
            return .success(text: text)
        case "stop":
            guard target.delegation != nil else { return .failure("@\(target.label) isn't handed to the organizer") }
            store.stopDelegating(target, why: isUser ? "the user stopped it" : "the organizer stopped", tellOrganizer: isUser)
            return .success(text: "stopped handling @\(target.label)")
        default:
            return .failure("delegate takes handle, stop, or list")
        }
    }

    /// answer_prompt: approve or deny a permission request of a session handed to the organizer.
    private func answerForOrganizer(_ request: ControlRequest) -> ControlResponse {
        guard let target = resolve(request.target) else { return notFound(request.target) }
        guard let answer = PromptAnswer(rawValue: request.text ?? ""), answer != .always else {
            return .failure("answer must be approve or deny; never \"always\"")
        }
        let reason = request.label.map(sanitizeMessage).flatMap { $0.isEmpty ? nil : $0 }
        switch store.answerForOrganizer(target, answer, reason: reason) {
        case .success(let text): return .success(text: text)
        case .failure(let error): return .failure(error.description)
        }
    }

    /// Closing ends a process and whatever it hadn't saved, so the user confirms each one.
    private func closeForOrganizer(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        guard let target = resolve(request.target) else { reply(notFound(request.target)); return }
        guard !target.isOrganizer else { reply(.failure("the organizer can't close itself")); return }
        store.confirm("The organizer wants to close @\(target.label)", abbreviateHome(target.spec.workPath)) { [store] approved in
            guard approved else {
                reply(.failure("the user kept @\(target.label) open"))
                return
            }
            // It may have been closed while the sheet was up.
            guard store.sessions.contains(where: { $0.id == target.id }) else {
                reply(.success(text: "@\(target.label) was already closed"))
                return
            }
            store.close(target)
            reply(.success(text: "closed @\(target.label)"))
        }
    }

    /// Any of: a layout, a terminal to bring to the front, and the grid's exact tiles.
    private func arrange(_ request: ControlRequest) -> ControlResponse {
        var layout: LayoutMode?
        if let text = request.text, !text.isEmpty {
            guard let mode = LayoutMode(rawValue: text) else { return .failure("layout must be focus, split, or grid") }
            layout = mode
        }
        var focus: TerminalSession?
        if let target = request.target, !target.isEmpty {
            guard let session = resolve(target) else { return notFound(target) }
            guard !session.isOrganizer else { return .failure("the organizer stays in the sidebar; focus another terminal") }
            focus = session
        }
        var tiles: LayoutNode?
        if let spec = request.tiles {
            if let layout, layout != .grid { return .failure("tiles arrange the grid; leave layout out or pass grid") }
            var seen = Set<UUID>()
            switch tileNode(spec, seen: &seen) {
            case .success(let node): tiles = node
            case .failure(let error): return .failure(error.message)
            }
            if let focus, !seen.contains(focus.id) { return .failure("@\(focus.label) isn't one of the tiles") }
            layout = .grid
        }
        guard layout != nil || focus != nil || tiles != nil else { return .failure("pass a layout, a terminal to focus, or tiles") }
        if let focus { store.wake(focus) }
        store.arrange(layout: layout, focus: focus, tiles: tiles)
        return .success(text: "arranged")
    }

    private struct TileError: Error { let message: String }

    /// Labels resolve to sessions; each may appear once, and the organizer never takes a tile.
    private func tileNode(_ spec: TileSpec, seen: inout Set<UUID>) -> Result<LayoutNode, TileError> {
        if let label = spec.terminal {
            guard let session = resolve(label) else { return .failure(TileError(message: notFound(label).error ?? "unknown terminal")) }
            guard !session.isOrganizer else { return .failure(TileError(message: "the organizer stays in the sidebar; leave it out of the tiles")) }
            guard !session.isDetached else { return .failure(TileError(message: "@\(session.label) is in its own window; detach_terminals back first")) }
            guard seen.insert(session.id).inserted else { return .failure(TileError(message: "@\(session.label) appears twice")) }
            return .success(.leaf(session.id))
        }
        let axis: LayoutAxis
        switch spec.split {
        case "row": axis = .horizontal
        case "column": axis = .vertical
        default: return .failure(TileError(message: "each tile is a terminal label or a split of \"row\" or \"column\""))
        }
        let children = spec.children ?? []
        let sizes = spec.sizes ?? Array(repeating: 1, count: children.count)
        guard sizes.count == children.count, sizes.allSatisfy({ $0 > 0 }) else {
            return .failure(TileError(message: "sizes needs one positive number per child"))
        }
        var pairs: [(weight: Double, node: LayoutNode)] = []
        for (size, child) in zip(sizes, children) {
            switch tileNode(child, seen: &seen) {
            case .success(let node): pairs.append((size, node))
            case .failure(let error): return .failure(error)
            }
        }
        guard let node = LayoutNode.split(axis, pairs) else { return .failure(TileError(message: "a split needs children")) }
        return .success(node)
    }

    private func send(_ request: ControlRequest) -> ControlResponse {
        guard let target = resolve(request.target) else { return notFound(request.target) }
        let text = sanitizeMessage(request.text ?? "")
        guard !text.isEmpty else { return .failure("message is empty") }
        if let sender = callerAgent {
            if sender.id == target.id { return .failure("that's this terminal") }
            guard target.kind.isAgent else {
                return .failure("@\(target.label) is a \(target.kind.displayName.lowercased()); agents can read it or restart it, not type into it")
            }
            let framed = agentMessagePrefix + "\(sender.label) (\(sender.kind.displayName), via Tako): \(singleLine(text))"
            return .success(text: target.deliver(framed, from: sender.label))
        }
        guard isUser else { return .failure("not allowed from a detached process") }
        return .success(text: target.deliver(text, submit: request.submit ?? true, from: nil))
    }

    /// Agents can read agents and servers. Shell scrollback can hold secrets, so only the user
    /// reads shells.
    private func read(_ request: ControlRequest) -> ControlResponse {
        guard let target = resolve(request.target) else { return notFound(request.target) }
        if !isUser && target.kind == .shell && target.id != callerSession?.id {
            return .failure("@\(target.label) is a shell; agents can't read shells")
        }
        let lines = min(request.lines ?? 60, 2000)
        // Asleep, the terminal holds a bare shell; the agent's last screen is what was asked for.
        if let kept = target.asleepScreen {
            let screen = kept.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
            return .success(text: withConversation(of: target, screen: screen, lines: lines))
        }
        return .success(text: withConversation(of: target, screen: target.surface.readText(lastLines: lines), lines: lines))
    }

    /// Fullscreen agents hold one screenful; a read asking for more gets the conversation's
    /// tail from the transcript above the screen.
    private func withConversation(of target: TerminalSession, screen: String, lines: Int) -> String {
        let shown = screen.split(separator: "\n", omittingEmptySubsequences: false).count
        guard lines > shown + 1, target.kind.adapter != nil,
              let id = target.spec.agentSessionId else { return screen }
        let root = (AccountStore.shared.account(target.spec.account, kind: target.kind)
            ?? AgentAccount(id: AgentAccount.defaultID, kind: target.kind, name: "Default")).homeDirectory
        let conversation = AgentTranscript.conversation(
            kind: target.kind, id: id, cwds: [target.spec.workPath, expandTilde(target.spec.cwd)], root: root)
        return AgentTranscript.compose(conversation: conversation, screen: screen, lines: lines)
    }

    /// Agents rename only themselves, never over a name the user chose, and never onto a label
    /// someone else answers to.
    private func rename(_ request: ControlRequest) -> ControlResponse {
        guard let label = request.label, !normalizeLabel(label).isEmpty else { return .failure("label is empty") }
        if let me = callerAgent {
            if let target = request.target, !target.isEmpty, resolve(target)?.id != me.id {
                return .failure("agents can only rename their own terminal")
            }
            guard me.spec.agentMayRename else { return .failure("the user named this terminal @\(me.label); keep it") }
            if let holder = store.find(label), holder.id != me.id {
                return .failure("@\(normalizeLabel(label)) is taken by another terminal")
            }
            if store.isReserved(normalizeLabel(label)) { return .failure("@\(normalizeLabel(label)) was recently used by another terminal") }
            let old = me.label
            let new = store.rename(me, to: label, source: .agent) ?? old
            return .success(text: new == old ? "already @\(new)" : "renamed @\(old) → @\(new). Other terminals can still reach you at @\(old).")
        }
        guard isUser else { return .failure("not allowed from a detached process") }
        guard let target = resolve(request.target) else { return notFound(request.target) }
        let new = store.rename(target, to: label, source: .user)
        return .success(text: "@\(new ?? target.label)")
    }

    private func restart(_ request: ControlRequest) -> ControlResponse {
        guard let target = resolve(request.target) else { return notFound(request.target) }
        if !isUser {
            guard callerAgent != nil, target.kind == .server else { return .failure("agents can only restart servers") }
        }
        target.restart()
        return .success(text: "restarted @\(target.label)")
    }

    // MARK: - Approvals

    /// PermissionRequest hook: hold the hook open until the user decides in Tako, the agent
    /// moves on (answered in its own terminal), or the hook times out.
    private func handlePermission(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        guard let agent = callerAgent else {
            reply(.success())   // no decision: the CLI's own prompt handles it
            return
        }
        store.registerApproval(for: agent, source: request.source ?? "claude", payload: request.payload ?? "{}", reply: reply)
    }

    /// Newlines would submit early in most TUIs; flatten so one message is one prompt.
    private func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ⏎ ")
    }
}

/// Strips control characters (ESC, bracketed-paste markers, C0/C1) and bidi overrides from text
/// that will be typed into a terminal or shown in the UI. Newlines and tabs survive.
func sanitizeMessage(_ text: String) -> String {
    let bidi: ClosedRange<UInt32> = 0x202A...0x202E
    let isolates: ClosedRange<UInt32> = 0x2066...0x2069
    let scalars = text.unicodeScalars.filter { scalar in
        let value = scalar.value
        if value == 0x0A || value == 0x09 { return true }
        if value < 0x20 || (0x7F...0x9F).contains(value) { return false }
        return !bidi.contains(value) && !isolates.contains(value)
    }
    return String(String.UnicodeScalarView(scalars)).prefix(8000).description
}

/// How Tako starts a message it types into an agent on another agent's behalf.
let agentMessagePrefix = "Message from @"

func isAgentMessage(_ prompt: String) -> Bool {
    prompt.hasPrefix(agentMessagePrefix)
}
