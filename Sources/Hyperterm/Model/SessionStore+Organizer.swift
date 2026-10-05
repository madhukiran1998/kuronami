import Foundation

/// The organizer: one agent (Claude or Codex) behind the round button in the window's corner that
/// runs the user's other sessions. It starts agents in any project, arranges the tiles, and closes
/// what's done. It takes no tile and no card; its terminal opens in a floating panel.
extension SessionStore {
    var organizer: TerminalSession? { sessions.first(where: \.isOrganizer) }

    /// Its own Kuronami tools run without a permission prompt; the app still checks each call,
    /// and closing a terminal still asks.
    static let organizerTools = ["list_terminals", "read_terminal", "send_message", "start_agent", "arrange_view",
                                 "close_terminal", "save_layout", "restore_layout", "watch_terminal",
                                 "session_history", "reopen_session", "machine_status", "set_policy"]
        .map { "mcp__hyperterm__" + $0 }

    /// Which CLI runs the organizer, picked in its panel's header.
    static var organizerKind: SessionKind {
        get { UserDefaults.standard.string(forKey: "organizerKind").flatMap(SessionKind.init(rawValue:)) ?? .claude }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "organizerKind") }
    }

    /// Starts the organizer in `cwd`, replacing one that has exited. It runs with full access:
    /// its work spans every project, so it never stops to ask before reading or running something.
    func startOrganizer(cwd: String, task: String? = nil) {
        guard !organizerStarting else { return }
        if let organizer {
            guard organizer.isExitedProcess else { return }
            close(organizer)
        }
        var spec = LaunchSpec(label: "organizer", kind: Self.organizerKind, cwd: cwd)
        spec.organizer = true
        spec.options = AgentOptions(mode: .fullAccess)
        organizerStarting = true
        Task { @MainActor [spec] in
            await self.launch(spec, select: false, task: task)
            self.organizerStarting = false
        }
    }

    /// Runs the organizer on another CLI: the current one closes and a new one starts where it was.
    func switchOrganizer(to kind: SessionKind) {
        guard kind != Self.organizerKind || organizer == nil else { return }
        Self.organizerKind = kind
        let cwd = organizer?.spec.cwd ?? selected.map { $0.git?.mainRoot ?? $0.spec.cwd } ?? NSHomeDirectory()
        if let organizer { close(organizer) }
        startOrganizer(cwd: cwd)
    }

    // MARK: - Arranging

    /// The organizer's view request. `tiles` sets the grid exactly: the sessions it names show in
    /// that shape, servers it leaves out go to the strip, and everything else to the shelf.
    func arrange(layout: LayoutMode?, focus: TerminalSession?, tiles: LayoutNode?) {
        if let tiles {
            let shown = Set(tiles.leaves)
            for session in sessions where !session.isOrganizer {
                if session.kind == .server {
                    session.pinnedToGrid = shown.contains(session.id)
                } else {
                    session.spec.minimized = shown.contains(session.id) ? nil : true
                }
            }
            persist()
            onArrangeTiles?(tiles)
        }
        // Focus first: a selected session outside the tiles would otherwise show and take space.
        let target = focus ?? tiles.flatMap { root in sessions.first { $0.id == root.leaves.first } }
        if let target { select(target) }
        if let tiles { setTileOrder(tiles.leaves) }
        if let layout { setLayout(layout) }
    }

    // MARK: - Named layouts

    struct SavedLayout: Codable {
        var layout: LayoutMode
        var focus: String?
        /// The grid's shape by label, so it survives restarts and renames back.
        var tiles: TileSpec?
    }

    private static let layoutsKey = "organizerLayouts"

    var savedLayouts: [String: SavedLayout] {
        guard let data = UserDefaults.standard.data(forKey: Self.layoutsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: SavedLayout].self, from: data)) ?? [:]
    }

    /// Remembers the window as it is now under `name`.
    func saveLayout(_ name: String) {
        var tiles: TileSpec?
        if layout == .grid, let root = LayoutTreeStore.load(LayoutMode.grid.rawValue)?.root {
            tiles = tileSpec(root)
        }
        var all = savedLayouts
        all[name] = SavedLayout(layout: layout, focus: selected?.label, tiles: tiles)
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: Self.layoutsKey) }
    }

    /// Puts a saved layout back. Terminals closed since then are skipped; nil when none is left.
    func restoreLayout(_ name: String) -> [String]? {
        guard let saved = savedLayouts[name] else { return nil }
        let tiles = saved.tiles.flatMap(layoutNode)
        var focus = saved.focus.flatMap(find)
        if let shown = focus, shown.isOrganizer || tiles.map({ !$0.contains(shown.id) }) == true { focus = nil }
        if saved.tiles != nil && tiles == nil && focus == nil { return nil }
        arrange(layout: saved.layout, focus: focus, tiles: tiles)
        let shown = tiles?.leaves ?? focus.map { [$0.id] } ?? []
        return shown.compactMap { id in sessions.first { $0.id == id }?.label }
    }

    private func tileSpec(_ node: LayoutNode) -> TileSpec? {
        switch node {
        case .leaf(let id):
            return sessions.first { $0.id == id }.map { TileSpec(terminal: $0.label) }
        case .split(let axis, let weights, let children):
            let pairs = zip(weights, children).compactMap { weight, child in tileSpec(child).map { (weight, $0) } }
            guard !pairs.isEmpty else { return nil }
            return TileSpec(split: axis == .horizontal ? "row" : "column", sizes: pairs.map(\.0), children: pairs.map(\.1))
        }
    }

    /// Lenient: labels that no longer exist drop out, and their space goes to their neighbors.
    private func layoutNode(_ spec: TileSpec) -> LayoutNode? {
        var seen = Set<UUID>()
        func build(_ spec: TileSpec) -> LayoutNode? {
            if let label = spec.terminal {
                guard let session = find(label), !session.isOrganizer, seen.insert(session.id).inserted else { return nil }
                return .leaf(session.id)
            }
            let axis: LayoutAxis = spec.split == "column" ? .vertical : .horizontal
            let children = spec.children ?? []
            let sizes = spec.sizes.flatMap { $0.count == children.count ? $0 : nil } ?? children.map { _ in 1 }
            return LayoutNode.split(axis, zip(sizes, children).compactMap { size, child in build(child).map { (size, $0) } })
        }
        return build(spec)
    }

    // MARK: - History

    /// Closed agents it can reopen, newest first, in `folder` or below. Its own past runs are
    /// left out: reopening one would start a second organizer.
    func closedSessions(in folder: String? = nil) -> [LaunchSpec] {
        let root = folder.map { (expandTilde($0) as NSString).standardizingPath }
        return recentlyClosed.filter { spec in
            guard spec.organizer != true else { return false }
            guard let root else { return true }
            let path = (expandTilde(spec.cwd) as NSString).standardizingPath
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    /// The closed session `name` means: its label (or an earlier one) or its id. Newest wins.
    func closedSession(named name: String) -> LaunchSpec? {
        let id = UUID(uuidString: name.trimmingCharacters(in: .whitespaces))
        let label = normalizeLabel(name)
        return closedSessions().first { $0.id == id || $0.label == label || $0.previousLabels?.contains(label) == true }
    }

    /// session_history's reply: enough about each closed session to tell them apart and pick.
    static func describeHistory(_ specs: [LaunchSpec], now: Date = Date()) -> String {
        let relative = RelativeDateTimeFormatter()
        relative.locale = Locale(identifier: "en_US_POSIX")
        func ago(_ date: Date) -> String { relative.localizedString(for: date, relativeTo: now) }
        func oneLine(_ text: String, _ limit: Int) -> String {
            let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
        }
        return specs.map { spec in
            let memory = spec.memory
            var head = "@\(spec.label) [\(spec.kind.rawValue)] \(abbreviateHome(expandTilde(spec.cwd)))"
            if let branch = spec.worktreeBranch { head += " (branch \(branch))" }
            head += " · started " + ago(spec.createdAt)
            if let closed = memory?.closedAt { head += ", closed " + ago(closed) }
            head += spec.agentSessionId == nil ? " · starts fresh" : " · resumes its conversation"
            var lines = [head]
            if let state = memory?.finalState { lines.append("    ended: " + oneLine(state, 160)) }
            if let summary = spec.summary { lines.append("    summary: " + oneLine(summary, 200)) }
            if let task = memory?.task { lines.append("    task: " + oneLine(task, 200)) }
            for event in memory?.events ?? [] { lines.append("    - " + oneLine(event, 160)) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    // MARK: - Watching

    /// Above this much context in use, the organizer starts a fresh conversation before a digest.
    static let organizerClearPercent: Double = 60

    /// Gathers what the organizer should hear about this change, so one agent's finished work can
    /// start the next. It wakes once for the digest, not once per event.
    func reportToOrganizer(_ session: TerminalSession, from previous: AgentState) {
        guard let organizer else { return }
        if organizer.id == session.id { flushOrganizerDigest(); return }
        guard let event = organizerEvent(session, from: previous) else { return }
        addToOrganizerDigest(event)
    }

    /// The steward saw something it won't act on alone; the organizer checks and tells the user.
    func reportToOrganizer(_ escalation: Escalation) {
        guard organizer != nil else { return }
        addToOrganizerDigest(OrganizerEvent(label: escalation.label, kind: .steward(escalation.message)))
    }

    private func addToOrganizerDigest(_ event: OrganizerEvent) {
        if organizerDigest.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + OrganizerDigest.window) { [weak self] in
                self?.flushOrganizerDigest()
            }
        }
        organizerDigest.add(event)
    }

    /// What this change means for the organizer, if anything. A watched terminal ending its turn
    /// uses up the watch; other kinds of event go here.
    private func organizerEvent(_ session: TerminalSession, from previous: AgentState) -> OrganizerEvent? {
        guard let note = organizerWatches[session.id] else { return nil }
        let kind: OrganizerEvent.Kind
        switch session.state {
        case .idle where previous == .working: kind = .finished(session.summary ?? "turn complete")
        case .failed(let reason): kind = .failed(reason)
        case .exited: kind = .exited
        default: return nil
        }
        organizerWatches[session.id] = nil
        return OrganizerEvent(label: session.label, kind: kind, note: note.isEmpty ? nil : note)
    }

    /// Sends the digest once its window has passed and the organizer isn't mid-turn; the
    /// organizer's own next state change tries again. A mostly full context is cleared first.
    func flushOrganizerDigest(now: Date = Date()) {
        guard let organizer, !organizer.isExitedProcess else { organizerDigest = OrganizerDigest(); return }
        guard organizerDigest.isDue(at: now), !organizerDigest.clearing,
              organizer.atRest || organizer.state.needsAttention else { return }
        if organizer.usage.contextPercent ?? 0 >= Self.organizerClearPercent, organizer.startFreshConversation() {
            organizerDigest.clearing = true
            deliverDigestAfterClear(attempts: 10)
            return
        }
        if let message = organizerDigest.take() { _ = organizer.deliver(message, from: nil) }
    }

    /// Waits for the organizer to be back at an empty prompt after clearing, then sends the digest.
    private func deliverDigestAfterClear(attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            guard let organizer = self.organizer else { self.organizerDigest = OrganizerDigest(); return }
            if attempts > 1, !(organizer.atRest && organizer.inputIsEmpty && !organizer.dialogOnScreen) {
                self.deliverDigestAfterClear(attempts: attempts - 1)
                return
            }
            self.organizerDigest.clearing = false
            if let message = self.organizerDigest.take(cleared: true) { _ = organizer.deliver(message, from: nil) }
        }
    }
}

/// Something the organizer should hear about.
struct OrganizerEvent: Equatable {
    enum Kind: Equatable {
        case finished(String), failed(String), exited, steward(String)
    }

    var label: String
    var kind: Kind
    /// The note watch_terminal left for this terminal.
    var note: String?

    var line: String {
        var line = "@\(label) "
        switch kind {
        case .finished(let summary): line += "finished: " + summary
        case .failed(let reason): line += "failed: " + reason
        case .exited: line += "exited"
        case .steward(let warning): line += "steward warning: " + warning
        }
        if let note { line += " (your note: \(note))" }
        return line
    }
}

/// Events gathered for a few seconds, and while the organizer is mid-turn, so it wakes once for
/// all of them. The message stays on one line: a typed newline would submit it early.
struct OrganizerDigest {
    static let window: TimeInterval = 3

    private(set) var events: [OrganizerEvent] = []
    private var since: Date?
    /// The organizer is starting a fresh conversation; the digest waits for it.
    var clearing = false

    var isEmpty: Bool { events.isEmpty }

    mutating func add(_ event: OrganizerEvent, at now: Date = Date()) {
        if events.isEmpty { since = now }
        events.append(event)
    }

    func isDue(at now: Date) -> Bool {
        guard let since else { return false }
        return now.timeIntervalSince(since) >= Self.window
    }

    /// The message for everything gathered so far; the digest starts over empty.
    mutating func take(cleared: Bool = false) -> String? {
        guard !events.isEmpty else { return nil }
        defer { events = []; since = nil }
        return Self.message(events, cleared: cleared)
    }

    static func message(_ events: [OrganizerEvent], cleared: Bool = false) -> String {
        var text = "Kuronami: "
        if cleared { text += "Context was cleared. Read \(ControlPaths.organizerNotes) if you need earlier context. " }
        if events.count == 1 {
            text += events[0].line
        } else {
            text += "\(events.count) updates: " + events.enumerated().map { "[\($0 + 1)] \($1.line)" }.joined(separator: " ")
        }
        return text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
