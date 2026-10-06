import Foundation

/// The organizer: one agent (Claude or Codex) behind the round button in the window's corner that
/// runs the user's other sessions. It starts agents in any project, arranges the tiles, and closes
/// what's done. It takes no tile and no card; its terminal opens in a floating panel.
extension SessionStore {
    var organizer: TerminalSession? { sessions.first(where: \.isOrganizer) }

    /// Its own Tako tools run without a permission prompt; the app still checks each call,
    /// and closing a terminal still asks.
    static let organizerTools = ["list_terminals", "read_terminal", "send_message", "start_agent", "arrange_view",
                                 "close_terminal", "save_layout", "restore_layout", "watch_terminal",
                                 "session_history", "reopen_session", "machine_status", "set_policy", "detach_terminals",
                                 "handle_waiting", "stop_handling", "answer_prompt", "phone_mode"]
        .map { "mcp__hyperterm__" + $0 }

    /// Where the organizer runs. Its own folder, trusted once: Claude Code asks to trust the home
    /// folder again on every launch, and the organizer reaches every project with absolute paths.
    static var organizerFolder: String {
        let folder = ControlPaths.supportDirectory.appendingPathComponent("organizer")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.path
    }

    static let organizerKindKey = "organizerKind"
    /// Where the choice is kept. A variable so tests can use their own suite.
    static var organizerDefaults = UserDefaults.standard

    /// The CLIs that can run the organizer: every agent kind.
    static var organizerChoices: [SessionKind] { SessionKind.allCases.filter(\.isAgent) }

    /// The CLI the user picked to run the organizer; nil until they first do.
    static var chosenOrganizerKind: SessionKind? {
        organizerDefaults.string(forKey: organizerKindKey).flatMap(SessionKind.init(rawValue:)).flatMap { $0.isAgent ? $0 : nil }
    }

    /// Which CLI runs the organizer: picked the first time its panel opens, then in its header or Settings.
    static var organizerKind: SessionKind {
        get { chosenOrganizerKind ?? .claude }
        set { organizerDefaults.set(newValue.rawValue, forKey: organizerKindKey) }
    }

    /// The panel asks which CLI, then which model, instead of starting one. One already running
    /// (from before there was a choice) counts as chosen.
    var organizerNeedsChoice: Bool {
        guard organizer == nil else { return false }
        guard let kind = Self.chosenOrganizerKind else { return true }
        return Self.chosenOrganizerModel(for: kind) == nil
    }

    /// The first-run choice: remembered, then the organizer starts on it once its model is picked.
    func chooseOrganizer(_ kind: SessionKind) {
        Self.organizerKind = kind
        if Self.chosenOrganizerModel(for: kind) != nil { startOrganizer() }
    }

    // MARK: - Its model

    /// A model the organizer can run on. Its work is starting, arranging and watching agents, so
    /// a small model does it well for far fewer tokens.
    struct OrganizerModel: Equatable, Identifiable {
        /// Passed to the CLI as its model; nil leaves the CLI's own default.
        var name: String?
        var title: String
        var detail: String
        var recommended = false

        var id: String { name ?? "" }
    }

    /// Smallest first. Codex's names come from its model catalog (`codex debug models`).
    static func organizerModels(for kind: SessionKind) -> [OrganizerModel] {
        switch kind {
        case .claude: return [
            OrganizerModel(name: "haiku", title: "Haiku", detail: "Smallest and fastest. Plenty for starting, arranging and watching agents.", recommended: true),
            OrganizerModel(name: "sonnet", title: "Sonnet", detail: "Mid-size, for long plans across many agents."),
            OrganizerModel(name: nil, title: "Claude Code's default", detail: "Usually Opus: the most tokens per turn."),
        ]
        case .codex: return [
            OrganizerModel(name: "gpt-6-luna", title: "GPT-6-Luna", detail: "Fast and affordable. Plenty for starting, arranging and watching agents.", recommended: true),
            OrganizerModel(name: nil, title: "Codex's default", detail: "Its workhorse model: more tokens per turn."),
        ]
        default: return []
        }
    }

    private static func organizerModelKey(_ kind: SessionKind) -> String { "organizerModel." + kind.rawValue }

    /// The model picked for `kind`: nil until picked, "" for the CLI's own default.
    static func chosenOrganizerModel(for kind: SessionKind) -> String? {
        organizerDefaults.string(forKey: organizerModelKey(kind))
    }

    static func setOrganizerModel(_ name: String?, for kind: SessionKind) {
        organizerDefaults.set(name ?? "", forKey: organizerModelKey(kind))
    }

    /// What the organizer is launched with: nil for the CLI's default.
    static func organizerModel(for kind: SessionKind) -> String? {
        chosenOrganizerModel(for: kind).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The model step's choice: remembered, then the organizer starts on it, replacing one running.
    func chooseOrganizerModel(_ name: String?) {
        Self.setOrganizerModel(name, for: Self.organizerKind)
        if let organizer, !organizer.isExitedProcess { close(organizer) }
        startOrganizer()
    }

    /// Starts the organizer in `cwd`, replacing one that has exited. It runs with full access:
    /// its work spans every project, so it never stops to ask before reading or running something.
    func startOrganizer(task: String? = nil) {
        guard !organizerStarting else { return }
        if let organizer {
            guard organizer.isExitedProcess else { return }
            close(organizer)
        }
        var spec = LaunchSpec(label: "organizer", kind: Self.organizerKind, cwd: Self.organizerFolder)
        spec.organizer = true
        spec.options = AgentOptions(mode: .fullAccess, model: Self.organizerModel(for: Self.organizerKind))
        organizerStarting = true
        Task { @MainActor [spec] in
            await self.launch(spec, select: false, task: task)
            self.organizerStarting = false
            if self.remoteControlWhenOrganizerUp, let organizer = self.organizer {
                self.remoteControlWhenOrganizerUp = false
                if self.isPhoneModeOn { organizer.openRemoteControl() }
            }
            // The CLI was switched while this one was starting.
            if let organizer = self.organizer, organizer.kind != Self.organizerKind { self.switchOrganizer(to: Self.organizerKind) }
        }
    }

    /// Runs the organizer on another CLI: the current one closes and a new one starts where it was.
    /// A CLI it hasn't run on yet waits in the panel for its model to be picked.
    func switchOrganizer(to kind: SessionKind) {
        guard kind != organizer?.kind || organizer == nil else { Self.organizerKind = kind; return }
        Self.organizerKind = kind
        if kind != .claude { setPhoneMode(false) }
        if let organizer { close(organizer) }
        if Self.chosenOrganizerModel(for: kind) != nil { startOrganizer() }
    }

    // MARK: - Arranging

    /// Sessions the organizer just started, reopened or resumed. Opening several takes several
    /// calls, so whatever it opened in the last 20 s shows together: one fills the view, two or
    /// three sit side by side, more go in rows of three.
    func showOpenedByOrganizer(_ opened: [TerminalSession]) {
        let now = Date()
        organizerOpened.removeAll { entry in now.timeIntervalSince(entry.at) > 20 || !sessions.contains { $0.id == entry.id } }
        organizerOpened += opened.map { (id: $0.id, at: now) }
        let group = organizerOpened.compactMap { entry in sessions.first { $0.id == entry.id } }
        guard group.count > 1 else {
            if let only = group.first { select(only) }
            return
        }
        let rows = stride(from: 0, to: group.count, by: 3).map { start -> LayoutNode in
            let row = group[start..<min(start + 3, group.count)].map { LayoutNode.leaf($0.id) }
            return row.count == 1 ? row[0] : .split(axis: .horizontal, weights: row.map { _ in 1 }, children: row)
        }
        let tiles = rows.count == 1 ? rows[0] : LayoutNode.split(axis: .vertical, weights: rows.map { _ in 1 }, children: rows)
        arrange(layout: .grid, focus: opened.last, tiles: tiles)
    }

    /// The organizer's view request. `tiles` sets the grid exactly: the sessions it names show in
    /// that shape, servers it leaves out go to the strip, and everything else to the shelf.
    func arrange(layout: LayoutMode?, focus: TerminalSession?, tiles: LayoutNode?) {
        if let tiles {
            let shown = Set(tiles.leaves)
            for session in sessions where !session.isOrganizer {
                if session.kind == .server {
                    session.pinnedToGrid = shown.contains(session.id)
                    if shown.contains(session.id) { session.spec.minimized = nil }
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
        // An exited organizer would drop the event; the watch keeps until it can hear.
        guard !organizer.isExitedProcess, let event = organizerEvent(session, from: previous) else { return }
        addToOrganizerDigest(event)
    }

    /// The steward saw something it won't act on alone; the organizer checks and tells the user.
    func reportToOrganizer(_ escalation: Escalation) {
        guard organizer != nil else { return }
        addToOrganizerDigest(OrganizerEvent(label: escalation.label, kind: .steward(escalation.message)))
    }

    func addToOrganizerDigest(_ event: OrganizerEvent) {
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
        // Background subagents outlive the turn; their last SubagentStop reports it instead.
        case .idle where previous == .working && session.runningSubagents.isEmpty:
            kind = .finished(session.summary ?? "turn complete")
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
        /// A session handed to the organizer is waiting, with the user's note for it.
        case needsYou(String, note: String?)
        case stoppedHandling(String)
        /// The user turned Phone Mode on or off; not about one terminal.
        case phoneMode(Bool)
    }

    var label: String
    var kind: Kind
    /// The note watch_terminal left for this terminal.
    var note: String?

    var line: String {
        var line = "@\(label) "
        switch kind {
        case .needsYou(let reason, let note):
            return line + "is waiting: " + reason + (note.map { " (handle per: \($0))" } ?? "")
        case .stoppedHandling(let why):
            return "stopped handling @\(label): " + why
        case .phoneMode(true):
            return "Phone Mode is on: the user is away and talks to you from their phone. Kuronami approves agents' "
                + "ordinary requests itself; you handle every agent's questions and risky requests. Tell the user what's "
                + "waiting, and approve a risky one with answer_prompt user_approved true only after they say yes to it."
        case .phoneMode(false):
            return "Phone Mode is off: the user is back at the Mac, and agents' waits go to them again."
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
        var text = "Tako: "
        if cleared { text += "Context was cleared. Read \(ControlPaths.organizerNotes) if you need earlier context. " }
        if events.count == 1 {
            text += events[0].line
        } else {
            text += "\(events.count) updates: " + events.enumerated().map { "[\($0 + 1)] \($1.line)" }.joined(separator: " ")
        }
        return text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
