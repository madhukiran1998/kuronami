import AppKit

/// What a multi-agent harness adds on top of the terminals: turn checkpoints, forking, sending
/// one task to several agents, reopening closed agents, resuming after a rate limit, and one-click
/// project actions.
extension SessionStore {
    // MARK: - Checkpoints

    /// Records a turn boundary for an agent in a Git workspace. Starts close any turn left open
    /// (an interrupt never sends Stop), so turns never overlap.
    func checkpoint(_ session: TerminalSession, phase: Checkpoints.Phase, prompt: String) {
        guard session.kind.isAgent, AppSettings.checkpointsEnabled else { return }
        let path = session.spec.workPath, id = session.id.uuidString
        let title = summarize(prompt, limit: 120) ?? "Turn"
        checkpointQueue.async { [weak session] in
            let turns = Checkpoints.turns(at: path, session: id)
            let open = turns.last.flatMap { $0.end == nil ? $0 : nil }
            switch phase {
            case .start:
                if let open { Checkpoints.capture(at: path, session: id, turn: open.index, phase: .end, prompt: open.prompt) }
                Checkpoints.capture(at: path, session: id, turn: (turns.last?.index ?? 0) + 1, phase: .start, prompt: title)
            case .end:
                guard let open else { return }
                Checkpoints.capture(at: path, session: id, turn: open.index, phase: .end, prompt: open.prompt)
            }
            let updated = Checkpoints.turns(at: path, session: id)
            DispatchQueue.main.async { [weak session] in
                MainActor.assumeIsolated { if session?.turns != updated { session?.turns = updated } }
            }
        }
    }

    /// Reads a session's recorded turns (after a restart, or when the inspector opens).
    func loadTurns(_ session: TerminalSession) {
        guard session.kind.isAgent else { return }
        let path = session.spec.workPath, id = session.id.uuidString
        checkpointQueue.async { [weak session] in
            let turns = Checkpoints.turns(at: path, session: id)
            DispatchQueue.main.async { [weak session] in
                MainActor.assumeIsolated { if session?.turns != turns { session?.turns = turns } }
            }
        }
    }

    /// Puts the agent's files back to how they were at `commit`. The agent's conversation is
    /// untouched; it's told what happened so it doesn't assume its edits are still there.
    func restoreCheckpoint(_ session: TerminalSession, to commit: String, label: String,
                           completion: @escaping @MainActor (Result<String, CheckpointError>) -> Void) {
        let path = session.spec.workPath, id = session.id.uuidString
        checkpointQueue.async { [weak self, weak session] in
            let result = Checkpoints.restore(at: path, to: commit, session: id)
            DispatchQueue.main.async { [weak self, weak session] in
                MainActor.assumeIsolated {
                    guard let session else { return }
                    if case .success = result {
                        session.record(.note, "Files restored to \(label)")
                        if session.state == .idle {
                            _ = session.deliver("Note: I restored the workspace files to \(label). Re-read any file before editing it.", from: nil)
                        }
                        self?.refreshReview(session)
                    }
                    completion(result)
                }
            }
        }
    }

    // MARK: - Fork

    /// A new Claude agent that continues this conversation from where it is now; the original
    /// carries on unchanged. Both work in the same folder.
    @discardableResult
    func fork(_ session: TerminalSession) -> Bool {
        guard session.kind == .claude, let conversation = session.spec.agentSessionId else { return false }
        var spec = LaunchSpec(label: session.label + "-fork", kind: .claude, cwd: session.spec.workPath)
        spec.labelSource = .auto
        spec.forkOf = conversation
        spec.options = session.spec.options
        spec.account = session.spec.account
        spec.baseBranch = session.spec.baseBranch
        spec.port = session.spec.port
        Task { @MainActor [weak self, spec] in
            guard let self else { return }
            let fork = await self.launch(spec, resume: false)
            fork.record(.note, "Forked from @\(session.label)")
            session.record(.note, "Forked into @\(fork.label)")
        }
        return true
    }

    // MARK: - Dispatch to several agents

    /// Starts one agent per entry in `kinds` on the same task, each in its own worktree, so their
    /// results can be compared side by side and the best one merged.
    func dispatch(_ task: String, kinds: [SessionKind], cwd: String, options: AgentOptions?) {
        let base = labelFromTask(task)
        let mixed = Set(kinds).count > 1
        let race = kinds.count > 1 ? UUID() : nil
        for (index, kind) in kinds.enumerated() {
            var label = base
            if mixed { label += "-" + kind.rawValue } else if kinds.count > 1 { label += "-\(index + 1)" }
            var spec = LaunchSpec(label: label, kind: kind, cwd: cwd)
            spec.labelSource = .auto
            spec.options = options
            spec.race = race
            let select = index == 0
            Task { @MainActor [weak self, spec] in
                guard let self else { return }
                await self.launch(spec, select: select, isolateIfPossible: true, task: task)
            }
        }
        if kinds.count > 1, layout == .focus { setLayout(.grid) }
    }

    // MARK: - Races

    /// The other agents started on the same task.
    func raceSiblings(of session: TerminalSession) -> [TerminalSession] {
        guard let race = session.spec.race else { return [] }
        return sessions.filter { $0.id != session.id && $0.spec.race == race }
    }

    /// Keeps `winner`'s work: commits what it left uncommitted, merges its branch into the base
    /// branch, then closes the other agents and archives their worktrees (their branches stay,
    /// so nothing is lost).
    func pickWinner(_ winner: TerminalSession, completion: @escaping @MainActor (Result<String, ReviewError>) -> Void) {
        guard let base = winner.spec.baseBranch, let branch = winner.git?.branch, branch != base else {
            completion(.failure(.git("@\(winner.label) isn't on its own branch")))
            return
        }
        let path = winner.spec.workPath
        let root = winner.git.map(GitInfo.mainRoot) ?? path
        let label = winner.label
        let losers = raceSiblings(of: winner).map { (session: $0, path: $0.spec.workPath, id: $0.id.uuidString,
                                                    isWorktree: $0.spec.worktreeBranch != nil || $0.spec.worktreeName != nil) }
        DispatchQueue.global(qos: .userInitiated).async {
            if !(Git.run(["status", "--porcelain"], at: path) ?? "").isEmpty {
                _ = Review.commit(at: path, message: "Work from @\(label) (Kuronami)")
            }
            let merged = Review.merge(branch: branch, into: base, mainRoot: root)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard case .success = merged else { completion(merged); return }
                    winner.record(.note, "Picked: merged \(branch) into \(base)")
                    winner.spec.race = nil
                    for loser in losers { self.close(loser.session) }
                    // Closing stops each agent; its worktree lock goes with it a moment later.
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
                        for loser in losers where loser.isWorktree {
                            _ = Review.archive(worktree: loser.path, mainRoot: root)
                            Checkpoints.prune(at: root, session: loser.id)
                        }
                    }
                    let others = losers.count
                    completion(.success("Merged \(branch) into \(base)" + (others > 0 ? "; closed \(others) other agent\(others == 1 ? "" : "s")" : "")))
                }
            }
        }
    }

    // MARK: - Recently closed

    nonisolated private static var recentlyClosedURL: URL { ControlPaths.supportDirectory.appendingPathComponent("closed.json") }

    nonisolated static func loadRecentlyClosed() -> [LaunchSpec] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: recentlyClosedURL) else { return [] }
        return (try? decoder.decode([LaunchSpec].self, from: data)) ?? []
    }

    /// Agents with a conversation to resume are kept for reopening.
    func rememberClosed(_ session: TerminalSession) {
        guard session.kind.isAgent, session.spec.agentSessionId != nil else { return }
        var spec = session.spec
        spec.minimized = nil
        recentlyClosed.removeAll { $0.id == spec.id }
        recentlyClosed.insert(spec, at: 0)
        if recentlyClosed.count > 15 { recentlyClosed.removeLast(recentlyClosed.count - 15) }
        saveRecentlyClosed()
    }

    func reopen(_ spec: LaunchSpec) {
        recentlyClosed.removeAll { $0.id == spec.id }
        saveRecentlyClosed()
        // A worktree archived since closing can't be resumed; start in the main folder instead.
        var spec = spec
        if !FileManager.default.fileExists(atPath: spec.workPath) {
            spec.worktreeName = nil
            spec.worktreeBranch = nil
        }
        spec.label = sessions.contains { $0.label == spec.label } ? "" : spec.label
        create(spec, resume: true)
    }

    func forgetClosed() {
        recentlyClosed = []
        saveRecentlyClosed()
    }

    private func saveRecentlyClosed() {
        let specs = recentlyClosed
        let url = Self.recentlyClosedURL
        DispatchQueue.global(qos: .utility).async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(specs) { try? data.write(to: url, options: .atomic) }
        }
    }

    // MARK: - Rate limits

    /// When the account's limit resets, tells the agent to carry on.
    func continueAtReset(_ session: TerminalSession) {
        guard let reset = [rateLimits?.fiveHourResets, rateLimits?.sevenDayResets].compactMap({ $0 })
            .filter({ $0 > Date() }).min() else { return }
        session.resumeAt = reset
        session.record(.note, "Will continue at \(reset.formatted(date: .omitted, time: .shortened))")
        // A minute's grace: resets land on the minute, and the first request after one can still bounce.
        let delay = reset.timeIntervalSinceNow + 60
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak session] in
            guard let session, session.resumeAt == reset else { return }
            session.resumeAt = nil
            _ = session.deliver("Your usage limit has reset. Continue where you left off.", from: nil)
        }
    }

    func cancelContinue(_ session: TerminalSession) {
        session.resumeAt = nil
    }

    /// The reset time to offer, when an agent stopped on a rate limit.
    func rateLimitReset(for session: TerminalSession) -> Date? {
        guard case .failed(let reason) = session.state, reason.lowercased().contains("rate") else { return nil }
        return [rateLimits?.fiveHourResets, rateLimits?.sevenDayResets].compactMap { $0 }.filter { $0 > Date() }.min()
    }

    // MARK: - Project actions

    /// The selected session's project actions: declared ones, else ones detected from manifests.
    func projectActions(for session: TerminalSession?) -> [ProjectAction] {
        guard let session, session.kind != .browser else { return [] }
        let path = session.spec.workPath
        if let declared = ProjectConfig.load(for: path)?.actions, !declared.isEmpty { return declared }
        let root = session.git?.root ?? path
        return ProjectAction.detect(at: root)
    }

    /// Runs an action next to `session`: servers go to the shelf on the agent's own port; other
    /// commands open a shell tile that keeps the output.
    func run(_ action: ProjectAction, for session: TerminalSession) {
        let kind: SessionKind = action.isServer ? .server : .shell
        let label = normalizeLabel("\(session.label)-\(action.name)")
        if let existing = sessions.first(where: { $0.label == label && $0.kind == kind }) {
            existing.restart()
            select(existing)
            return
        }
        var spec = LaunchSpec(label: label, kind: kind, cwd: session.spec.workPath, command: action.command)
        spec.labelSource = .auto
        if action.isServer, let port = session.spec.port {
            spec.port = port
            spec.command = action.command.replacingOccurrences(of: "$PORT", with: String(port))
        }
        create(spec, select: !action.isServer)
    }

    // MARK: - Labels

    /// "fix the flaky auth tests please" → "fix-flaky-auth".
    func labelFromTask(_ task: String) -> String {
        let stop: Set<String> = ["the", "a", "an", "to", "and", "of", "in", "on", "for", "please", "can", "you", "with", "is", "it", "that", "this", "my"]
        let words = task.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !stop.contains($0) }
        return normalizeLabel(words.prefix(3).joined(separator: "-"))
    }
}
