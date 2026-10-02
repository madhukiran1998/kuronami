import AppKit
import Combine

/// The set of sessions, which one is shown, and the rules that connect signals to sessions.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selectedID: UUID?
    @Published private(set) var layout: LayoutMode = LayoutMode(rawValue: UserDefaults.standard.string(forKey: "layout") ?? "") ?? .focus

    /// Called when a session's surface view is created or replaced, so the window can mount it.
    var onSurfaceChange: ((TerminalSession) -> Void)?
    /// Called whenever the visible set, layout, or focused session changes.
    var onArrangementChange: (() -> Void)?
    var onRemove: ((TerminalSession) -> Void)?
    var onSearchUpdate: ((TerminalSession, Int?, Int?, Bool) -> Void)?

    /// Most recently selected first; split view shows the top two.
    private var recent: [UUID] = []
    @Published var inspectorTab: InspectorTab = .changes

    /// "2 agents waiting · 3 working" under the window title.
    var windowSubtitle: String {
        var parts: [String] = []
        if attentionCount > 0 { parts.append("\(attentionCount) waiting") }
        let working = sessions.filter { $0.state == .working }.count
        if working > 0 { parts.append("\(working) working") }
        if reviewCount > 0 { parts.append("\(reviewCount) to review") }
        if parts.isEmpty { parts.append(sessions.isEmpty ? "No terminals" : "\(sessions.count) terminal\(sessions.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// Shown once by the window, then cleared.
    @Published var lastError: String?
    private var layoutBeforeZoom: LayoutMode?

    /// Account-wide usage windows, from the most recent statusLine report of any Claude session.
    @Published var rateLimits: RateLimits?
    /// Labels of closed user-named terminals, kept from agents for an hour so messages meant for
    /// them can't be captured by a rename.
    private var reservedLabels: [String: Date] = [:]
    var approvals: [UUID: PendingApproval] = [:]
    /// Channel delivery (opt-in): each Claude session's MCP server long-polls for messages.
    private var channelWaiters: [UUID: ControlServer.Reply] = [:]
    private var channelInbox: [UUID: [String]] = [:]
    private var channelLastSeen: [UUID: Date] = [:]

    nonisolated static var channelsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "channels") }
        set { UserDefaults.standard.set(newValue, forKey: "channels") }
    }

    func subscribeChannel(_ session: TerminalSession, reply: @escaping ControlServer.Reply) {
        channelLastSeen[session.id] = Date()
        if let queued = channelInbox.removeValue(forKey: session.id), !queued.isEmpty {
            var response = ControlResponse.success()
            response.messages = queued
            reply(response)
            return
        }
        channelWaiters.removeValue(forKey: session.id)?(ControlResponse.success())
        channelWaiters[session.id] = reply
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self, let waiting = self.channelWaiters.removeValue(forKey: session.id) else { return }
            waiting(ControlResponse.success())
        }
    }

    /// Pushes a message as a channel event when the session's channel is live. Returns false when
    /// the session has no channel, so the caller types the message instead.
    func pushViaChannel(_ text: String, to session: TerminalSession) -> Bool {
        guard Self.channelsEnabled, session.kind == .claude,
              let seen = channelLastSeen[session.id], Date().timeIntervalSince(seen) < 60 else { return false }
        if let waiter = channelWaiters.removeValue(forKey: session.id) {
            var response = ControlResponse.success()
            response.messages = [text]
            waiter(response)
        } else {
            channelInbox[session.id, default: []].append(text)
        }
        return true
    }
    /// Shows an in-app confirmation; set by the window controller.
    var confirmHandler: ((String, String, @escaping (Bool) -> Void) -> Void)?

    private var childCancellables: [UUID: AnyCancellable] = [:]
    private var persistWork: DispatchWorkItem?
    let notifier = AttentionNotifier()

    var selected: TerminalSession? { sessions.first { $0.id == selectedID } }

    /// Sessions on screen for the current layout, in a stable (creation) order so tiles don't
    /// jump around as states change.
    var visibleIDs: [UUID] {
        switch layout {
        case .focus:
            return selectedID.map { [$0] } ?? []
        case .split:
            let pair = Set(recent.prefix(2))
            return sessions.filter { pair.contains($0.id) }.map(\.id)
        case .grid:
            // Servers live in the strip below the canvas unless pinned or selected.
            return sessions.filter { session in
                (session.kind != .server || session.pinnedToGrid || session.id == selectedID)
                    && (!isExited(session) || session.id == selectedID)
            }.map(\.id)
        }
    }

    private func isExited(_ session: TerminalSession) -> Bool {
        if case .exited = session.state { return true }
        return false
    }

    func setLayout(_ mode: LayoutMode) {
        layoutBeforeZoom = nil
        guard layout != mode else { return }
        layout = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "layout")
        onArrangementChange?()
    }

    /// Zoom a tile to fill the window, or return to the layout it came from.
    func toggleZoom(_ id: UUID? = nil) {
        if layout == .focus, let previous = layoutBeforeZoom {
            layoutBeforeZoom = nil
            layout = previous
        } else if layout != .focus {
            layoutBeforeZoom = layout
            layout = .focus
        }
        if let id, let session = sessions.first(where: { $0.id == id }) { select(session) } else { onArrangementChange?() }
    }

    /// Sidebar order: needs-you first, then by creation.
    var grouped: [(title: String, sessions: [TerminalSession])] {
        let sorted = sessions.sorted {
            ($0.state.groupRank, $0.spec.createdAt) < ($1.state.groupRank, $1.spec.createdAt)
        }
        var groups: [(String, [TerminalSession])] = []
        for session in sorted {
            let title = session.state.groupTitle
            if let last = groups.last, last.0 == title {
                groups[groups.count - 1].1.append(session)
            } else {
                groups.append((title, [session]))
            }
        }
        return groups.map { (title: $0.0, sessions: $0.1) }
    }

    var attentionCount: Int { sessions.filter { $0.state.needsAttention }.count }
    var reviewCount: Int { sessions.filter(\.readyForReview).count }

    /// Creation order everywhere: positions never shift when states change, so muscle memory
    /// (⌘1–9, where a card sits) stays valid. Attention is shown, not sorted.
    var orderedSessions: [TerminalSession] { sessions }

    /// Agents grouped by repository (worktrees join their main repo), in creation order.
    var projects: [(name: String, agents: [TerminalSession])] {
        var order: [String] = []
        var groups: [String: [TerminalSession]] = [:]
        for session in sessions where session.kind.isAgent {
            let name = session.git?.project ?? "Scratch"
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(session)
        }
        return order.map { (name: $0, agents: groups[$0] ?? []) }
    }

    var utilities: [TerminalSession] { sessions.filter { !$0.kind.isAgent } }

    // MARK: - Lifecycle

    @discardableResult
    func create(_ spec: LaunchSpec, resume: Bool = false, select: Bool = true, worktree: Bool = false, task: String? = nil) -> TerminalSession {
        var spec = spec
        if spec.label.isEmpty, let task, !task.isEmpty { spec.label = labelFromTask(task) }
        spec.label = uniqueLabel(spec.label.isEmpty ? defaultLabel(for: spec) : spec.label, excluding: spec.id)
        if worktree, !resume, spec.kind.isAgent {
            switch Workspaces.prepare(spec: spec) {
            case .success(let prepared):
                spec = prepared
            case .failure(let error):
                lastError = "Worktree not created: \(error.description). Started in \(abbreviateHome(spec.cwd)) instead."
            }
        }
        if spec.kind.isAgent, spec.port == nil, let config = ProjectConfig.load(for: expandTilde(spec.cwd)) {
            spec.port = Ports.allocate(config: config, taken: Set(sessions.compactMap(\.spec.port)))
        }
        let session = TerminalSession(spec: spec, resume: resume, task: task.map(sanitizeMessage))
        if let task, !task.isEmpty { session.record(.prompt, task) }
        session.store = self
        sessions.append(session)
        // Re-publish child changes so SwiftUI lists refresh when any row's state changes.
        childCancellables[session.id] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        onSurfaceChange?(session)
        if select { self.select(session) }
        persist()
        if !resume { startDevServerIfConfigured(for: session) }
        return session
    }

    /// A project's `.hyperterm.json` "dev" command runs next to each new agent workspace, on the
    /// agent's own port.
    private func startDevServerIfConfigured(for agent: TerminalSession) {
        guard agent.kind.isAgent, agent.spec.worktreeBranch != nil || agent.spec.worktreeName != nil,
              let port = agent.spec.port else { return }
        let path = agent.spec.workPath
        Workspaces.whenReady(path) { [weak self] in
            guard let self, self.sessions.contains(where: { $0.id == agent.id }),
                  let config = ProjectConfig.load(for: path) ?? ProjectConfig.load(for: expandTilde(agent.spec.cwd)),
                  let dev = config.dev else { return }
            var command = dev.replacingOccurrences(of: "$PORT", with: String(port))
            if let setup = config.setup { command = "\(setup) && \(command)" }
            var server = LaunchSpec(label: "\(agent.label)-dev", kind: .server, cwd: path, command: command)
            server.labelSource = .auto
            server.port = port
            self.create(server, select: false)
        }
    }

    /// "fix the flaky auth tests please" → "fix-flaky-auth".
    private func labelFromTask(_ task: String) -> String {
        let stop: Set<String> = ["the", "a", "an", "to", "and", "of", "in", "on", "for", "please", "can", "you", "with", "is", "it", "that", "this", "my"]
        let words = task.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !stop.contains($0) }
        return normalizeLabel(words.prefix(3).joined(separator: "-"))
    }

    func close(_ session: TerminalSession) {
        dropApproval(for: session)
        if session.spec.labelSource == .user || session.spec.labelSource == nil {
            reservedLabels[session.label] = Date()
        }
        session.terminate()
        sessions.removeAll { $0.id == session.id }
        childCancellables[session.id] = nil
        recent.removeAll { $0 == session.id }
        onRemove?(session)
        if selectedID == session.id { select(sessions.last) }
        persist()
        notifier.updateBadge(count: attentionCount)
    }

    func select(_ session: TerminalSession?) {
        if let previous = selected { previous.lastViewedAt = Date() }
        selectedID = session?.id
        if let session {
            if session.unread { session.unread = false }
            recent.removeAll { $0 == session.id }
            recent.insert(session.id, at: 0)
        }
        onArrangementChange?()
    }

    @discardableResult
    func rename(_ session: TerminalSession, to raw: String, source: LabelSource = .user) -> String? {
        let base = normalizeLabel(raw)
        guard !base.isEmpty else { return nil }
        let label = uniqueLabel(base, excluding: session.id)
        if label != session.label {
            var previous = session.spec.previousLabels ?? []
            previous.removeAll { $0 == label }
            previous.append(session.label)
            session.spec.previousLabels = Array(previous.suffix(8))
            session.spec.label = label
            session.syncNativeName()
        }
        session.spec.labelSource = source
        persist()
        onArrangementChange?()
        return label
    }

    func isReserved(_ label: String) -> Bool {
        reservedLabels = reservedLabels.filter { Date().timeIntervalSince($0.value) < 3600 }
        return reservedLabels[label] != nil
    }

    func confirm(_ title: String, _ message: String, completion: @escaping (Bool) -> Void) {
        guard let confirmHandler else { completion(false); return }
        confirmHandler(title, message, completion)
    }

    /// Hands naming back to the agent.
    func releaseLabel(_ session: TerminalSession) {
        session.spec.labelSource = .auto
        persist()
    }

    func sessionSurfaceReplaced(_ session: TerminalSession) {
        onSurfaceChange?(session)
        onArrangementChange?()
    }

    // MARK: - Lookup

    func find(_ target: String) -> TerminalSession? {
        if let uuid = UUID(uuidString: target) { return sessions.first { $0.id == uuid } }
        let label = normalizeLabel(target)
        return sessions.first { $0.label == label }
            ?? sessions.first { ($0.spec.previousLabels ?? []).contains(label) }
    }

    func session(forEnvironmentID id: String?) -> TerminalSession? {
        guard let id, let uuid = UUID(uuidString: id) else { return nil }
        return sessions.first { $0.id == uuid }
    }

    // MARK: - Navigation

    func selectNextNeedingAttention() {
        let waiting = sessions
            .filter { $0.state.needsAttention || $0.unread }
            .sorted { $0.stateChangedAt < $1.stateChangedAt }
        if let next = waiting.first(where: { $0.id != selectedID }) ?? waiting.first { select(next) }
    }

    /// Sidebar order: agents by project, then servers and shells.
    var navigationOrder: [TerminalSession] { projects.flatMap(\.agents) + utilities }

    func selectRelative(_ offset: Int) {
        let ordered = navigationOrder
        guard !ordered.isEmpty else { return }
        let index = ordered.firstIndex { $0.id == selectedID } ?? 0
        select(ordered[(index + offset + ordered.count) % ordered.count])
    }

    func select(index: Int) {
        let ordered = navigationOrder
        guard ordered.indices.contains(index) else { return }
        select(ordered[index])
    }

    // MARK: - Session callbacks

    func sessionStateChanged(_ session: TerminalSession, from previous: AgentState) {
        notifier.updateBadge(count: attentionCount)
        onArrangementChange?()
        let isVisible = visibleIDs.contains(session.id) && NSApp.isActive
        switch session.state {
        case .needsInput(let reason):
            if !isVisible { session.unread = true }
            notifier.post(session: session, title: "@\(session.label) needs you", body: reason, foreground: !isVisible)
        case .idle where previous == .working && session.kind.isAgent:
            if !isVisible {
                session.unread = true
                notifier.post(session: session, title: "@\(session.label) finished", body: session.summary ?? "Turn complete", foreground: false)
            }
        case .failed(let reason):
            if !isVisible { session.unread = true }
            notifier.post(session: session, title: "@\(session.label) failed", body: reason, foreground: !isVisible)
        case .exited(let code) where session.kind == .server && code != 0:
            session.unread = true
            notifier.post(session: session, title: "@\(session.label) crashed", body: "exit \(code)", foreground: true)
        default:
            break
        }
    }

    func sessionWantsAttention(_ session: TerminalSession, title: String, body: String) {
        guard !visibleIDs.contains(session.id) || !NSApp.isActive else { return }
        session.unread = true
    }

    /// Clicking into a tile's terminal makes it the selected session.
    func sessionFocused(_ session: TerminalSession) {
        if selectedID != session.id { select(session) }
    }

    // MARK: - Persistence

    private var stateFile: URL { ControlPaths.supportDirectory.appendingPathComponent("sessions.json") }

    func persist() {
        persistWork?.cancel()
        let specs = sessions.map(\.spec)
        let url = stateFile
        let work = DispatchWorkItem {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(specs) else { return }
            try? data.write(to: url, options: .atomic)
        }
        persistWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func restore() -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: stateFile),
              let specs = try? decoder.decode([LaunchSpec].self, from: data), !specs.isEmpty else { return false }
        // Drop summaries derived from the old title-only heuristic.
        specs.map { spec -> LaunchSpec in
            var spec = spec
            if spec.summary == spec.label { spec.summary = nil }
            return spec
        }.forEach { create($0, resume: true, select: false) }
        select(sessions.first)
        return true
    }

    // MARK: - Labels

    private func defaultLabel(for spec: LaunchSpec) -> String {
        let folder = URL(fileURLWithPath: expandTilde(spec.cwd)).lastPathComponent
        switch spec.kind {
        case .server: return normalizeLabel(folder + "-server")
        case .shell: return normalizeLabel(folder)
        default: return normalizeLabel(folder)
        }
    }

    /// Labels are addresses, so they must be unique: api, api-2, api-3.
    private func uniqueLabel(_ base: String, excluding id: UUID) -> String {
        let taken = Set(sessions.filter { $0.id != id }.map(\.label))
        guard taken.contains(base) else { return base }
        var counter = 2
        while taken.contains("\(base)-\(counter)") { counter += 1 }
        return "\(base)-\(counter)"
    }
}

