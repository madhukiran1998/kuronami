import AppKit
import Combine

/// One labeled terminal: its launch spec, its live libghostty surface, and what it's doing.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id: UUID
    @Published var spec: LaunchSpec
    @Published private(set) var state: AgentState = .starting
    @Published private(set) var stateSource = "launch"
    @Published private(set) var stateChangedAt = Date()
    @Published var summary: String? {
        didSet {
            guard summary != oldValue else { return }
            spec.summary = summary
            store?.persist()
        }
    }
    /// Not published: agent TUIs animate their title many times a second and no view shows it.
    private(set) var title: String = ""
    @Published var ports: [Int] = []
    @Published var foregroundProcess: String?
    @Published var unread = false
    /// What the agent is doing this moment ("Bash: pnpm test"), from tool-use hooks.
    @Published var activity: String?
    /// The agent's own one-line status, posted with the set_status tool.
    @Published var agentStatus: String?
    /// The request an agent is blocked on ("Bash: pnpm prisma migrate dev"), when known.
    @Published var pendingRequest: String?
    /// True while a PermissionRequest hook is held open, so approvals go through the CLI's API.
    @Published var hasHookApproval = false
    @Published var git: GitInfo?
    @Published var timeline: [TimelineEvent] = []
    @Published var usage = UsageSnapshot()
    @Published var tasks = TaskProgress()
    @Published var testEvidence: TestEvidence?
    @Published var diffStat: DiffStat?
    /// Finished a turn with changes that the user hasn't opened in review yet.
    @Published var readyForReview = false
    /// Servers normally sit in the canvas's strip; pinned ones get a grid tile.
    @Published var pinnedToGrid = false
    /// When the user last looked at this session; the recap covers events after it.
    @Published var lastViewedAt = Date()
    /// Checkpointed turns, oldest first (git workspaces only).
    @Published var turns: [Checkpoints.Turn] = []
    /// The plan an agent in plan mode is waiting to have approved.
    @Published var pendingPlan: String?
    /// Set while a "continue at reset" is scheduled after a rate limit.
    @Published var resumeAt: Date?
    /// Review comments drafted in the Changes tab and not yet sent.
    @Published var reviewComments: [ReviewComment] = []
    /// The agent CLI quit to free its memory; its screen stays and its conversation resumes on
    /// the next message or keystroke. Status events are ignored meanwhile.
    @Published private(set) var isAsleep = false
    /// Relaunched from sleep and not yet at its prompt; keystrokes wait in `wakeDraft`.
    @Published private(set) var isWaking = false
    /// What the user typed while it slept or woke, put in the agent's prompt once it is ready.
    private var wakeDraft = ""
    /// The screen text when it fell asleep, for readers (the terminal itself now holds a shell).
    private(set) var asleepScreen: String?

    /// Whether the agent CLI process has been seen running in this terminal.
    var agentProcessSeen = false
    private(set) var createdAt = Date()
    /// Hook ordering: events stamped earlier than the newest applied one are stale.
    var lastHookSentAt: UInt64 = 0
    var lastHookAt = Date.distantPast

    private(set) var surface: any SessionSurface
    /// Messages for an agent that is blocked on a prompt or mid-turn; delivered when it is free
    /// so typed text can't land in a permission dialog or interrupt the turn.
    @Published private(set) var pendingMessages: [String] = []
    /// The command to type once the shell shows its first prompt.
    private var pendingInput: String?
    /// The shell reported a prompt (OSC 7) and nothing was typed since, so input lands at it.
    private var shellAtPrompt = false
    private var inputGeneration = 0
    /// A label Claude Code itself should adopt via /rename at its next idle prompt, so its
    /// native SendMessage name matches the Kuronami label.
    private var pendingNativeRename: String?
    weak var store: SessionStore?

    var label: String { spec.label }
    var kind: SessionKind { spec.kind }
    var isMinimized: Bool { spec.minimized == true }
    var isOrganizer: Bool { spec.organizer == true }

    init(spec: LaunchSpec, resume: Bool, task: String? = nil) {
        self.id = spec.id
        self.spec = spec
        self.surface = TerminalSessionFactory.makeSurface(spec: spec)
        self.surface.events = self
        self.summary = spec.summary.flatMap { $0.hasPrefix("~") || $0.count < 3 ? nil : $0 }
        if !spec.kind.isAgent { state = .running }
        // A known id makes resume independent of hooks reporting it.
        if spec.kind == .claude, spec.agentSessionId == nil, spec.forkOf == nil {
            self.spec.agentSessionId = UUID().uuidString.lowercased()
        }
        if spec.asleep == true, spec.kind.isAgent {
            // Restored asleep: a plain shell until something wakes it.
            isAsleep = true
            state = .idle
        } else {
            scheduleInitialInput(resume: resume, task: task)
        }
        bindBrowser()
    }

    /// A browser's page is its status: the title becomes its summary, the address is persisted
    /// so it reopens there.
    private func bindBrowser() {
        guard let browser = surface as? BrowserSurfaceView else { return }
        browser.onNavigate = { [weak self] url, title in
            guard let self else { return }
            let address = url?.absoluteString == "about:blank" ? nil : url?.absoluteString
            if self.spec.url != address {
                self.spec.url = address
                self.store?.persist()
            }
            let summary = title.isEmpty ? address.map(abbreviateURL) : title
            if self.summary != summary { self.summary = summary }
        }
    }

    /// Keeps a browser's page tag in step with its label.
    func labelChanged() {
        (surface as? BrowserSurfaceView)?.label = label
    }

    /// Typing before the shell is ready makes the tty echo the command above the prompt. Shell
    /// integration reports the first prompt via OSC 7 (pwd); fall back to a timer without it.
    private func scheduleInitialInput(resume: Bool, task: String? = nil) {
        inputGeneration += 1
        let generation = inputGeneration
        pendingInput = AgentIntegration.initialInput(for: spec, resume: resume, task: task)
        guard pendingInput != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.inputGeneration == generation else { return }
            self.sendPendingInput()
        }
    }

    private func sendPendingInput() {
        guard let input = pendingInput else { return }
        pendingInput = nil
        shellAtPrompt = false
        surface.sendText(input.trimmingCharacters(in: .newlines))
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
            self?.surface.sendReturn()
        }
    }

    /// Kills the current process and starts the same spec again. Queued messages survive.
    func restart() {
        store?.dropApproval(for: self)
        endSleep()
        isWaking = false
        wakeDraft = ""
        shellAtPrompt = false
        surface.events = nil
        surface.destroy()
        surface.removeFromSuperview()
        surface = TerminalSessionFactory.makeSurface(spec: spec)
        surface.events = self
        bindBrowser()
        scheduleInitialInput(resume: true)
        ports = []
        agentProcessSeen = false
        createdAt = Date()
        lastHookSentAt = 0
        apply(.processStarted, source: "restart", force: kind.isAgent ? .starting : .running)
        store?.sessionSurfaceReplaced(self)
    }

    func terminate() {
        inputGeneration += 1
        surface.events = nil
        surface.destroy()
        surface.removeFromSuperview()
    }

    // MARK: - Sleep

    /// Quits the agent CLI with its own exit command, holding its last frame on screen. The
    /// store checks it is idle at an empty prompt first.
    func fallAsleep() {
        asleepScreen = surface.readText(lastLines: 2000)
        (surface as? TerminalSurfaceView)?.freezeFrame()
        isAsleep = true
        spec.asleep = true
        record(.note, "Asleep: the agent quit to free memory; its conversation resumes on the next message")
        type(kind == .codex ? "/quit" : "/exit", submit: true, countsAsWork: false)
    }

    /// Resumes the conversation in the same shell, which is back at its prompt.
    func wakeUp() {
        endSleep()
        isWaking = true
        record(.note, "Woke: resuming the conversation")
        scheduleInitialInput(resume: true)
        agentProcessSeen = false
        createdAt = Date()
        lastHookSentAt = 0
        apply(.processStarted, source: "wake", force: .starting)
        if shellAtPrompt { sendPendingInput() }
    }

    private func endSleep() {
        isAsleep = false
        asleepScreen = nil
        spec.asleep = nil
    }

    /// The agent is back at its prompt (or failed to start): the live terminal replaces the held
    /// frame, and what the user typed meanwhile becomes their draft.
    private func finishWaking() {
        isWaking = false
        (surface as? TerminalSurfaceView)?.thawFrame()
        let draft = wakeDraft
        wakeDraft = ""
        guard !draft.isEmpty, state == .idle || state == .working else { return }
        // A draft holds queued messages back, as one the user typed would.
        userDraftInProgress = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
            self?.surface.sendText(draft)
        }
    }

    /// Keystrokes while asleep or waking: the first wakes it; printable text is kept as a draft
    /// and Return queues it as a message, so nothing reaches the bare shell.
    private func interceptWhileAsleep(_ event: NSEvent) -> Bool {
        guard isAsleep || isWaking else { return false }
        if isAsleep { store?.wake(self) }
        if !event.modifierFlags.isDisjoint(with: [.command, .control]) { return true }
        let chars = event.characters ?? ""
        switch chars {
        case "\r":
            if !wakeDraft.isEmpty { pendingMessages.append(wakeDraft) }
            wakeDraft = ""
        case "\u{7f}":
            if !wakeDraft.isEmpty { wakeDraft.removeLast() }
        default:
            // Function and arrow keys arrive as private-use characters.
            if chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && !(0xF700...0xF8FF).contains($0.value) }) {
                wakeDraft += chars
            }
        }
        return true
    }

    // MARK: - Status

    func apply(_ event: StatusEvent, source: String, force: AgentState? = nil) {
        // Asleep, the agent's process is gone on purpose; its exit is not news.
        guard !isAsleep else { return }
        let next = force ?? reduceState(state, kind: kind, event: event)
        guard next != state else { return }
        if !next.needsAttention { pendingRequest = nil }
        if next == .idle || next == .exited(0) { activity = nil }
        let previous = state
        state = next
        stateSource = source
        stateChangedAt = Date()
        if isWaking, next != .starting { finishWaking() }
        // Codex has no prompt hook: a turn starts when work starts from rest. Claude's turns
        // come from its UserPromptSubmit and Stop hooks instead.
        if kind == .codex, next == .working, previous == .idle || previous == .starting,
           source != "approval", source != "process" {
            store?.checkpoint(self, phase: .start, prompt: lastPrompt ?? "Turn")
        }
        if previous.needsAttention && !next.needsAttention { flushPendingMessages() }
        if next == .idle {
            applyPendingNativeRename()
            if !pendingMessages.isEmpty { flushPendingMessages() }
        }
        store?.sessionStateChanged(self, from: previous)
    }

    /// Resume ids are typed into a shell on restore, so only id-shaped values are accepted.
    func recordAgentSessionId(_ value: String?) {
        guard let value, isSafeIdentifier(value), spec.agentSessionId != value else { return }
        spec.agentSessionId = value
        store?.persist()
    }

    func record(_ kind: TimelineEvent.Kind, _ text: String) {
        timeline.append(TimelineEvent(date: Date(), kind: kind, text: String(text.prefix(300))))
        if timeline.count > 300 { timeline.removeFirst(timeline.count - 300) }
    }

    // MARK: - Screen checks

    /// A selection dialog (permission prompt, question, menu) is on screen.
    var dialogOnScreen: Bool {
        let screen = surface.readViewport()
        return PromptScreen.hasDialog(screen)
    }

    /// The user typed into this terminal since their last submit. Screen text can't separate a
    /// draft from Claude's dimmed prompt suggestion, so keystrokes decide.
    private(set) var userDraftInProgress = false

    /// The agent's input box holds nothing the user is in the middle of typing.
    var inputIsEmpty: Bool { !userDraftInProgress }

    /// Called on each poll: delivers queued messages once the agent is free.
    func retryPendingMessages() {
        guard !pendingMessages.isEmpty, kind.isAgent else { return }
        if isAsleep { store?.wake(self); return }
        guard atRest, !isWaking else { return }
        flushPendingMessages()
    }

    /// At its prompt between turns. Queued messages wait for this: not mid-turn, not before the
    /// agent CLI is running (they'd run as shell commands), not after it exited. Codex stays
    /// "starting" until its first turn, so a running CLI counts as ready.
    private var atRest: Bool {
        if isAsleep { return false }
        switch state {
        case .idle, .failed: return true
        case .starting: return agentProcessSeen
        default: return false
        }
    }

    // MARK: - Prompts (keystroke fallback)

    /// Answers a prompt by pressing its numbered option. Used when no PermissionRequest hook is
    /// waiting (Codex, or prompts that aren't permission requests). Re-reads the screen first so
    /// a stale "needs you" can never become stray keystrokes.
    func answerPromptByKeys(_ answer: PromptAnswer) -> Result<String, PromptError> {
        guard kind.isAgent, state.needsAttention else { return .failure(.notWaiting(label)) }
        let screen = surface.readViewport()
        guard let keys = PromptScreen.keys(for: answer, screen: screen, kind: kind) else {
            return .failure(.noPromptOnScreen(label))
        }
        keys.forEach { _ = surface.pressKey(named: $0) }
        record(.approval, answer == .deny ? "Denied in Kuronami" : "Approved in Kuronami")
        apply(.userSubmitted, source: "approval", force: answer == .deny ? .idle : .working)
        return .success(answer == .deny ? "denied" : "approved")
    }

    enum PromptError: Error, CustomStringConvertible {
        case notWaiting(String), noPromptOnScreen(String), noAlwaysOption
        var description: String {
            switch self {
            case .notWaiting(let label): return "@\(label) isn't waiting on a prompt"
            case .noPromptOnScreen(let label): return "couldn't find the prompt on @\(label)'s screen; open it to answer"
            case .noAlwaysOption: return "this prompt has no \"don't ask again\" option"
            }
        }
    }

    // MARK: - Naming

    func syncNativeName() {
        guard kind == .claude else { return }
        pendingNativeRename = label
        if state == .idle { applyPendingNativeRename() }
    }

    /// Typed only at an idle, empty prompt so it never lands in the user's half-written message.
    private func applyPendingNativeRename() {
        guard let name = pendingNativeRename, kind == .claude, state == .idle, !isAsleep else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            guard let self, self.state == .idle, self.inputIsEmpty, !self.dialogOnScreen else { return }
            self.pendingNativeRename = nil
            self.type("/rename \(name)", submit: true, countsAsWork: false)
        }
    }

    /// Claude's Remote Control continues this session on the phone or web; typed only at an idle,
    /// empty prompt.
    func openRemoteControl() {
        guard kind == .claude else { return }
        if state == .idle && !isAsleep && inputIsEmpty && !dialogOnScreen {
            type("/remote-control", submit: true, countsAsWork: false)
        } else {
            pendingMessages.append("/remote-control")
            if isAsleep { store?.wake(self) }
        }
    }

    // MARK: - Messaging

    /// Types `text` into the terminal and submits it. For agents, text never lands in a dialog
    /// or a half-typed prompt: it waits until the agent is at an empty prompt.
    func deliver(_ text: String, submit: Bool = true, from sender: String?) -> String {
        if kind == .browser {
            return "@\(label) is a browser; use the browser tools (pageId for @\(label)) to act on it"
        }
        if kind.isAgent, isAsleep || isWaking {
            pendingMessages.append(text)
            if let sender { record(.message, "Message from @\(sender)") }
            if isAsleep { store?.wake(self) }
            return "queued: @\(label) was asleep; it wakes with the same conversation and gets the message once ready"
        }
        if submit, store?.pushViaChannel(text, to: self) == true {
            if let sender { record(.message, "Message from @\(sender)") }
            return "delivered to @\(label) (channel)"
        }
        if kind.isAgent && (state.needsAttention || dialogOnScreen || !inputIsEmpty) {
            pendingMessages.append(text)
            return "queued: @\(label) is busy at a prompt; it gets the message as soon as that clears"
        }
        type(text, submit: submit)
        if let sender { record(.message, "Message from @\(sender)") }
        return "delivered to @\(label)"
    }

    /// Sends a follow-up. While the agent is mid-turn it waits in the queue and goes out when the
    /// turn ends; `now` types it straight in (Claude reads it as steering the current turn).
    func send(_ text: String, now: Bool) -> String {
        let text = sanitizeMessage(text)
        guard !text.isEmpty else { return "" }
        if kind.isAgent, !now, state == .working || state == .starting {
            pendingMessages.append(text)
            return "queued"
        }
        return deliver(text, from: nil)
    }

    func removeQueued(at index: Int) {
        guard pendingMessages.indices.contains(index) else { return }
        pendingMessages.remove(at: index)
    }

    /// Sends a queued message right away instead of waiting for the turn to end.
    func sendQueuedNow(at index: Int) {
        guard pendingMessages.indices.contains(index), atRest || state == .working, !dialogOnScreen, inputIsEmpty else { return }
        type(pendingMessages.remove(at: index), submit: true)
    }

    /// One flush in flight at a time: two landing together (the idle transition and the poll)
    /// would both type before the first one's Return, merging two messages into one.
    private var flushScheduled = false

    private func flushPendingMessages() {
        guard !pendingMessages.isEmpty, !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
            self?.flushScheduled = false
            // One message per turn: the rest wait for the agent to finish the one just sent.
            guard let self, self.atRest, !self.dialogOnScreen,
                  self.inputIsEmpty, !self.pendingMessages.isEmpty else { return }
            let message = self.pendingMessages.removeFirst()
            // Kuronami's own slash commands start no turn, so they mustn't hold the queue.
            self.type(message, submit: true, countsAsWork: !message.hasPrefix("/remote-control"))
            if !self.pendingMessages.isEmpty { self.flushPendingMessages() }
        }
    }

    /// The last prompt Kuronami typed, used to title Codex checkpoints.
    private var lastPrompt: String?

    private func type(_ text: String, submit: Bool, countsAsWork: Bool = true) {
        if submit, countsAsWork { lastPrompt = summarize(text) ?? text }
        surface.sendText(text)
        guard submit else { return }
        // Let the paste land before Return so TUIs don't treat it as part of the paste.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
            self?.surface.sendReturn()
            if countsAsWork, self?.kind.isAgent == true { self?.apply(.userSubmitted, source: "message") }
        }
    }

    func info() -> SessionInfo {
        SessionInfo(
            id: id.uuidString, label: label, kind: kind.rawValue, state: isAsleep ? "asleep" : state.key,
            stateDetail: state.detail, summary: agentStatus ?? summary, title: title.isEmpty ? nil : title,
            cwd: abbreviateHome(spec.cwd), command: spec.command, ports: ports, unread: unread,
            agentSessionId: spec.agentSessionId, labelSource: (spec.labelSource ?? .user).rawValue,
            activity: activity, project: git?.project, branch: git?.branch,
            organizer: isOrganizer ? true : nil, asleep: isAsleep ? true : nil)
    }
}

// MARK: - Surface events

extension TerminalSession: TerminalSurfaceEvents {
    func surfaceTitleChanged(_ title: String) {
        let cleaned = cleanTitle(title)
        // Titles that are just a path (shells, Claude at rest) or the label say nothing new.
        let meaningless = cleaned.contains("/") || cleaned.hasPrefix("~") || cleaned.lowercased() == label
            || cleaned.lowercased() == kind.rawValue || cleaned.count < 3
        let next = meaningless ? "" : cleaned
        guard next != self.title else { return }
        self.title = next
        if kind.isAgent, summary == nil, !next.isEmpty { summary = next }
    }

    func surfacePwdChanged(_ pwd: String) {
        shellAtPrompt = true
        if pendingInput != nil { sendPendingInput() }
        guard !pwd.isEmpty, let url = URL(string: pwd), url.isFileURL || pwd.hasPrefix("/") else { return }
        let path = url.isFileURL ? url.path : pwd
        if kind == .shell, spec.cwd != path {
            spec.cwd = path
            store?.persist()
        }
    }

    func surfaceNotification(title: String, body: String) {
        apply(.terminalNotification(title: title, body: body), source: "osc9")
        if kind == .codex, !body.isEmpty { summary = summarize(body) }
        store?.sessionWantsAttention(self, title: title.isEmpty ? "@\(label)" : title, body: body)
    }

    func surfaceBell() {
        store?.sessionWantsAttention(self, title: "@\(label)", body: "Bell")
    }

    func surfaceChildExited(code: Int) {
        apply(.childExited(code), source: "process")
    }

    /// OSC 9;4 progress isn't shown anywhere yet.
    func surfaceProgress(active: Bool, percent: Int) {}

    /// A server's command returning means the server stopped; non-zero means it crashed.
    func surfaceCommandFinished(exitCode: Int) {
        guard kind == .server, state == .running else { return }
        apply(.childExited(exitCode), source: "shell integration")
    }

    func surfaceRequestedClose() {
        store?.close(self)
    }

    func surfaceProcessClosed(processAlive: Bool) {
        // The shell exited (e.g. the user typed `exit`): the terminal closes, as in Terminal.app.
        apply(.childExited(0), source: "process")
        store?.close(self)
    }

    func surfaceFocused() {
        if unread { unread = false }
        store?.sessionFocused(self)
    }

    func surfaceUserSubmitted() {
        userDraftInProgress = false
        // Typed by the user, so the last prompt Kuronami sent doesn't describe this turn.
        lastPrompt = nil
        apply(.userSubmitted, source: "keyboard")
    }

    func surfaceUserEdited(clearsDraft: Bool) {
        userDraftInProgress = !clearsDraft
    }

    func surfaceSearch(total: Int?, selected: Int?, start: Bool) {
        store?.onSearchUpdate?(self, total, selected, start)
    }

    func surfaceMentionRequested() {
        store?.onMentionRequest?(self)
    }

    func surfaceInterceptsKey(_ event: NSEvent) -> Bool {
        interceptWhileAsleep(event)
    }
}

@MainActor
enum TerminalSessionFactory {
    /// Set at launch; browsers offer the store's running servers on their start page.
    static weak var store: SessionStore?

    static func makeSurface(spec: LaunchSpec) -> any SessionSurface {
        if spec.kind == .browser, let store {
            // `ht new browser @docs -- <address>` passes the address as the command.
            let url = spec.url.flatMap(URL.init(string:)) ?? spec.command.flatMap(resolveAddress)
            return BrowserSurfaceView(url: url, label: spec.label, store: store)
        }
        return TerminalSurfaceView(launch: AgentIntegration.surfaceLaunch(for: spec))
    }
}

/// "https://github.com/acme/api/pulls" → "github.com/acme/api/pulls".
func abbreviateURL(_ address: String) -> String {
    guard let url = URL(string: address), let host = url.host() else { return address }
    let path = url.path()
    return host + (url.port.map { ":\($0)" } ?? "") + (path == "/" ? "" : path)
}

/// Ids typed into shells: letters, digits, dash, underscore, dot. No spaces or metacharacters.
func isSafeIdentifier(_ value: String) -> Bool {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    return (4...128).contains(value.count) && value.unicodeScalars.allSatisfy { allowed.contains($0) }
}

/// Reading agent TUIs from their screen text.
enum PromptScreen {
    /// Numbered option lines like "❯ 1. Yes" or "  2. Yes, and don't ask again".
    static func options(_ screen: String) -> [(number: Int, text: String)] {
        screen.split(separator: "\n").compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            for marker in ["❯", "›", ">"] where line.hasPrefix(marker) {
                line = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            }
            guard let dot = line.firstIndex(of: "."), let number = Int(line[..<dot]), (1...9).contains(number) else { return nil }
            return (number, String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces))
        }
    }

    static func hasDialog(_ screen: String) -> Bool {
        let lower = screen.lowercased()
        let asks = lower.contains("do you want") || lower.contains("would you like") || lower.contains("allow command")
            || lower.contains("proceed?") || lower.contains("trust this folder") || lower.contains("enter to confirm")
        return asks && options(screen).count >= 2
    }

    static func inputIsEmpty(_ screen: String, kind: SessionKind) -> Bool {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let marker = kind == .codex ? "›" : "❯"
        guard let prompt = lines.last(where: { $0.hasPrefix(marker) }) else { return true }
        let rest = prompt.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        // Claude shows a dim placeholder ("Try …") when empty; it can't be told from typed text
        // by characters alone, so treat the common placeholder forms as empty.
        return rest.isEmpty || rest.hasPrefix("Try \"") || rest.hasPrefix("Ask anything") || rest.hasPrefix("Implement {feature}")
    }

    /// Keys that choose `answer` in the dialog on screen, or nil when there is no dialog.
    static func keys(for answer: PromptAnswer, screen: String, kind: SessionKind) -> [String]? {
        let options = options(screen)
        guard hasDialog(screen) || kind == .codex, !options.isEmpty else { return nil }
        func pick(_ predicate: (String) -> Bool) -> [String]? {
            options.first { predicate($0.text.lowercased()) }.map { [String($0.number)] }
        }
        switch answer {
        case .approve:
            return pick { $0.hasPrefix("yes") && !$0.contains("don't ask") && !$0.contains("always") && !$0.contains("auto") }
        case .always:
            return pick { $0.contains("don't ask again") || $0.contains("always") }
        case .deny:
            return pick { $0.hasPrefix("no") } ?? ["esc"]
        }
    }
}
