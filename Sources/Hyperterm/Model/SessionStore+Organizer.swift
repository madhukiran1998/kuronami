import Foundation

/// The organizer: one agent (Claude or Codex) behind the round button in the window's corner that
/// runs the user's other sessions. It starts agents in any project, arranges the tiles, and closes
/// what's done. It takes no tile and no card; its terminal opens in a floating panel.
extension SessionStore {
    var organizer: TerminalSession? { sessions.first(where: \.isOrganizer) }

    /// Its own Kuronami tools run without a permission prompt; the app still checks each call,
    /// and closing a terminal still asks.
    static let organizerTools = ["list_terminals", "read_terminal", "send_message", "start_agent", "arrange_view",
                                 "close_terminal", "save_layout", "restore_layout", "watch_terminal"]
        .map { "mcp__hyperterm__" + $0 }

    /// Which CLI runs the organizer, picked in its panel's header.
    static var organizerKind: SessionKind {
        get { UserDefaults.standard.string(forKey: "organizerKind").flatMap(SessionKind.init(rawValue:)) ?? .claude }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "organizerKind") }
    }

    /// Sends `text` to the organizer, starting it in `cwd` the first time.
    func askOrganizer(_ text: String, cwd: String) {
        if let organizer, !organizer.isExitedProcess {
            _ = organizer.deliver(text, from: nil)
            return
        }
        startOrganizer(cwd: cwd, task: text)
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
