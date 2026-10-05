import Foundation

/// Conflict watch bookkeeping: at most one scan per repository at a time.
struct OverlapWatch {
    /// Repositories with a scan due, and the agents whose finished turns asked for it.
    var pending: [String: Set<UUID>] = [:]
    var running: Set<String> = []
    var notes = OverlapNotes()
}

/// "Conflicts with @bravo", with the files in its tooltip.
struct OverlapBadge: Equatable {
    let title: String
    let detail: String
}

extension TerminalSession {
    /// Overlapping agents by label, for list_terminals.
    var conflictsByLabel: [String: [String]]? {
        let named = overlapPartners
        return named.isEmpty ? nil : Dictionary(named.map { ($0.label, $0.files) }) { first, _ in first }
    }

    var overlapBadge: OverlapBadge? {
        let named = overlapPartners
        guard let first = named.first else { return nil }
        let title = "Conflicts with @\(first.label)" + (named.count > 1 ? " +\(named.count - 1)" : "")
        let detail = named.map { "Conflicts with @\($0.label): " + $0.files.joined(separator: ", ") }.joined(separator: "\n")
        return OverlapBadge(title: title, detail: detail)
    }

    private var overlapPartners: [(label: String, files: [String])] {
        guard let store else { return [] }
        return store.sessions.compactMap { other in overlaps[other.id].map { (other.label, $0) } }
    }
}

extension SessionStore {
    /// New worktrees get the main checkout's `.worktreeinclude` folders, cloned in the
    /// background; the agent starts without waiting, and the outcome lands on its timeline.
    func warmWorktree(_ session: TerminalSession) {
        let path = session.spec.workPath
        DispatchQueue.global(qos: .utility).async { [weak session] in
            let result = WorktreeInclude.warm(path)
            guard !result.copied.isEmpty || !result.failed.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !result.copied.isEmpty { session?.record(.note, "Cloned from the main checkout: " + result.copied.joined(separator: ", ")) }
                    if !result.failed.isEmpty { session?.record(.note, "Couldn't copy from the main checkout: " + result.failed.joined(separator: ", ")) }
                }
            }
        }
    }

    /// An agent finished a turn: compare its workspace with every other live agent's in the
    /// same repository, a few seconds later so turns ending together share one scan.
    func watchOverlaps(_ session: TerminalSession, from previous: AgentState) {
        guard session.state == .idle, previous == .working, session.kind.isAgent, !session.isOrganizer,
              let repo = session.git?.mainRoot else { return }
        let due = overlapWatch.pending[repo] != nil
        overlapWatch.pending[repo, default: []].insert(session.id)
        if !due, !overlapWatch.running.contains(repo) { scheduleOverlapScan(repo) }
    }

    /// A closed session no longer overlaps anyone.
    func forgetOverlaps(with session: TerminalSession) {
        for other in sessions where other.overlaps[session.id] != nil { other.overlaps[session.id] = nil }
    }

    private func scheduleOverlapScan(_ repo: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.scanOverlaps(repo) }
        }
    }

    private func scanOverlaps(_ repo: String) {
        guard !overlapWatch.running.contains(repo), let finished = overlapWatch.pending.removeValue(forKey: repo) else { return }
        let live = sessions.filter { session in
            guard session.kind.isAgent, !session.isOrganizer, session.git?.mainRoot == repo else { return false }
            if case .exited = session.state { return false }
            return true
        }
        guard live.count > 1, live.contains(where: { finished.contains($0.id) }) else { return }
        overlapWatch.running.insert(repo)
        let workspaces = live.map { (id: $0.id, path: $0.spec.workPath) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let pairs = Overlaps.scan(workspaces, focus: finished)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.applyOverlaps(pairs, finished: finished)
                    self.overlapWatch.running.remove(repo)
                    if self.overlapWatch.pending[repo] != nil { self.scheduleOverlapScan(repo) }
                }
            }
        }
    }

    private func applyOverlaps(_ pairs: [Overlaps.Pair], finished: Set<UUID>) {
        for pair in pairs {
            guard let a = sessions.first(where: { $0.id == pair.a }), let b = sessions.first(where: { $0.id == pair.b }) else { continue }
            let files = pair.files.isEmpty ? nil : pair.files
            if a.overlaps[b.id] != files { a.overlaps[b.id] = files }
            if b.overlaps[a.id] != files { b.overlaps[a.id] = files }
            guard !pair.files.isEmpty, overlapWatch.notes.shouldTell(a.id, b.id, files: pair.files) else { continue }
            // The agent that just finished tells the other one.
            let (author, reader) = finished.contains(a.id) ? (a, b) : (b, a)
            let shown = pair.files.prefix(5).joined(separator: ", ") + (pair.files.count > 5 ? " and \(pair.files.count - 5) more" : "")
            _ = reader.send("@\(author.label) just finished changes to \(shown) that overlap yours; check before continuing.", now: false)
        }
    }
}
