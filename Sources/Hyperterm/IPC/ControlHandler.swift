import AppKit

/// Maps control requests to store operations and enforces who may do what.
///
/// The caller comes from the kernel (`CallerIdentity`), never from the request. Fail closed:
/// - The user is a process outside Kuronami, or one traced to a shell/server terminal.
/// - Agents (traced to an agent terminal) may message other agents, read agents and servers,
///   restart servers, start servers with the user's OK, and rename only themselves.
/// - Anything else from inside Kuronami (detached, unknown) gets read-only access.
/// Only the user may press keys, answer prompts, close terminals, or type raw text: those would
/// let one agent answer another's permission prompts or run commands outside its own checks.
/// The organizer (the agent behind the sidebar's box) also starts agents in any folder, arranges
/// the view, and closes terminals once the user confirms.
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
        case .rename:
            return rename(request)
        case .notify:
            guard let target = callerSession ?? (isUser ? resolve(request.target) : nil) else { return notFound(request.target) }
            store.sessionWantsAttention(target, title: "@\(target.label)", body: sanitizeMessage(request.text ?? ""))
            return .success()
        case .permission, .subscribe, .browser:
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
            let brief = task + "\n\n(Delegated by @\(parent.label) through Kuronami. When you finish, use send_message to tell @\(parent.label) what you did and where.)"
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
        Task { @MainActor in
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
            // Several at once land side by side, like a project window opened for them.
            if count > 1 { store.arrange(layout: .grid, focus: started.first, tiles: nil) }
            let labels = started.map { "@" + $0.label }.joined(separator: ", ")
            var response = ControlResponse.success(text: "started \(labels) in \(abbreviateHome(expandTilde(folder)))")
            response.session = started.first?.info()
            reply(response)
        }
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
        store.organizerWatches[target.id] = note.isEmpty ? "(none)" : String(note.prefix(1000))
        return .success(text: "you'll get a message when @\(target.label) finishes its turn")
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
        store.arrange(layout: layout, focus: focus, tiles: tiles)
        return .success(text: "arranged")
    }

    private struct TileError: Error { let message: String }

    /// Labels resolve to sessions; each may appear once, and the organizer never takes a tile.
    private func tileNode(_ spec: TileSpec, seen: inout Set<UUID>) -> Result<LayoutNode, TileError> {
        if let label = spec.terminal {
            guard let session = resolve(label) else { return .failure(TileError(message: notFound(label).error ?? "unknown terminal")) }
            guard !session.isOrganizer else { return .failure(TileError(message: "the organizer stays in the sidebar; leave it out of the tiles")) }
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
            let framed = "Message from @\(sender.label) (\(sender.kind.displayName), via Kuronami): \(singleLine(text))"
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
        return .success(text: target.surface.readText(lastLines: min(request.lines ?? 60, 2000)))
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

    /// PermissionRequest hook: hold the hook open until the user decides in Kuronami, the agent
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
