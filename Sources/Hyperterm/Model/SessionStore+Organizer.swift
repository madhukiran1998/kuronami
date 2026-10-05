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
                                 "session_history", "reopen_session"]
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

    /// Tells the organizer when a terminal it is waiting on ends its turn, so it can hand the
    /// result on: one agent's finished work starts the next.
    func reportToOrganizer(_ session: TerminalSession, from previous: AgentState) {
        guard let note = organizerWatches[session.id], let organizer, organizer.id != session.id else { return }
        let outcome: String
        switch session.state {
        case .idle where previous == .working: outcome = "finished: " + (session.summary ?? "turn complete")
        case .failed(let reason): outcome = "failed: " + reason
        case .exited: outcome = "exited"
        default: return
        }
        organizerWatches[session.id] = nil
        let report = "Kuronami: @\(session.label) \(outcome) — Your note for this: \(note)"
        _ = organizer.deliver(report.split(whereSeparator: \.isNewline).joined(separator: " "), from: nil)
    }
}
