import AppKit

/// A session whose waits the user handed to Sumi, for as long as they said: its
/// questions and permission prompts wake Sumi instead of the user. The user still hears
/// about anything Sumi leaves, or doesn't answer within `fallback`.
struct Delegation: Equatable {
    enum Scope: Equatable {
        /// Until the agent finishes its current task: its next working → idle with nothing pending.
        case turn
        /// The next n waits.
        case count(Int)
        case until(Date)
        /// Every agent while the user is away in Phone Mode; ends when they turn it off.
        case phoneMode
    }

    var scope: Scope
    /// The user's instructions, e.g. "prefer pnpm".
    var note: String?
    /// Waits handled so far, answered or left for the user.
    var handled = 0
    /// When Sumi was told of the wait in progress.
    var toldAt: Date?
    /// Phone Mode: how many times Sumi was reminded of the wait in progress.
    var reminders = 0

    /// How long Sumi has before the user is notified anyway.
    static let fallback: TimeInterval = 90
    /// Phone Mode: reminders to Sumi before the wait also goes to the Mac.
    static let phoneReminders = 3

    func isUsedUp(at now: Date) -> Bool {
        switch scope {
        case .turn, .phoneMode: return false
        case .count(let limit): return handled >= limit
        case .until(let end): return now >= end
        }
    }

    func isOverdue(at now: Date) -> Bool {
        toldAt.map { now.timeIntervalSince($0) >= Self.fallback } ?? false
    }

    /// "turn", "2 left", "until 14:05".
    var shortScope: String {
        switch scope {
        case .turn: return "turn"
        case .count(let limit): return "\(max(limit - handled, 0)) left"
        case .until(let end): return "until " + Self.clock(end)
        case .phoneMode: return "phone"
        }
    }

    /// "until it finishes its task", "for its next 3 waits", "until 14:05".
    var scopePhrase: String {
        switch scope {
        case .turn: return "until it finishes its task"
        case .count(let limit): return limit == 1 ? "for its next wait" : "for its next \(limit) waits"
        case .until(let end): return "until " + Self.clock(end)
        case .phoneMode: return "while Phone Mode is on"
        }
    }

    /// Sumi tag's tooltip.
    var help: String {
        "Sumi answers this session's questions \(scopePhrase)." + (note.map { " Your note: \($0)" } ?? "")
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// Requests Sumi never approves on the user's behalf. The list lives here, in one
/// place, and the app checks it: Sumi's instructions alone are not the guard.
enum RiskyRequest {
    /// Each pattern (case-insensitive, against the full request) with what it means.
    static let patterns: [(pattern: String, why: String)] = [
        (#"\brm\b[^|;&\n]*\s(-[a-z]*r|--recursive)"#, "a recursive delete"),
        (#"\bsudo\b"#, "sudo"),
        (#"\bgit\b[^|;&\n]*\bpush\b"#, "a git push"),
        (#"\bgit\b[^|;&\n]*\breset\b[^|;&\n]*--hard\b"#, "git reset --hard"),
        (#"\bgit\b[^|;&\n]*\bclean\b"#, "git clean"),
        (#"\bchmod\b[^|;&\n]*\s(-[a-z]*r|--recursive)"#, "a recursive chmod"),
        (#"\b(curl|wget)\b[^;&\n]*\|\s*(sudo\s+)?(ba|z|da|k)?sh\b"#, "piping a download into a shell"),
        (#"\bdeploy"#, "a deploy"),
        (#"\b(npm|pnpm|yarn|cargo)\s+publish\b"#, "publishing a package"),
        (#"\bdrop\s+(table|database|schema)\b"#, "dropping a table or database"),
        (#"(^|[^a-z0-9_])\.env\b|secret|credential|keychain|\.ssh/|\.aws/|\.netrc\b|\bid_(rsa|ed25519)\b"#, "secrets or credentials"),
        (#"\bkill\s+(-9|-kill|-sigkill|-s\s+kill)\b|\bkillall\b|\bpkill\b"#, "force-killing processes"),
    ]

    static let fileWriteTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    private static let compiled: [(NSRegularExpression, String)] = patterns.compactMap { entry in
        (try? NSRegularExpression(pattern: entry.pattern, options: [.caseInsensitive])).map { ($0, entry.why) }
    }

    /// Why Sumi must leave this request for the user, or nil when it may approve it.
    static func reason(tool: String?, request: String, workspace: String?) -> String? {
        let range = NSRange(request.startIndex..., in: request)
        if let hit = compiled.first(where: { $0.0.firstMatch(in: request, range: range) != nil }) { return hit.1 }
        if let tool, fileWriteTools.contains(tool), let workspace, request.hasPrefix("/") {
            let path = (request as NSString).standardizingPath
            let root = (expandTilde(workspace) as NSString).standardizingPath
            if path != root && !path.hasPrefix(root.hasSuffix("/") ? root : root + "/") { return "a write outside its workspace" }
        }
        return nil
    }

    /// The whole request a permission hook asks about, not the one-line summary: the full
    /// command, the absolute path, or the tool's input.
    static func text(tool: String, input: [String: Any]) -> String {
        if let command = input["command"] as? String { return command }
        if let parts = input["command"] as? [String] { return parts.joined(separator: " ") }
        if let path = (input["file_path"] ?? input["notebook_path"]) as? String { return path }
        let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return tool + " " + String(decoding: data, as: UTF8.self)
    }
}

extension SessionStore {
    /// handle_waiting: replaces any earlier handoff. A session already waiting is Sumi's
    /// from now; the reply describes that wait.
    func delegate(_ session: TerminalSession, scope: Delegation.Scope, note: String?, now: Date = Date()) -> String? {
        var delegation = Delegation(scope: scope, note: note)
        session.record(.note, "Sumi handling: " + delegation.scopePhrase + (note.map { " (\($0))" } ?? ""))
        if case .until(let end) = scope { scheduleDelegationSweep(after: end.timeIntervalSince(now)) }
        defer { session.delegation = delegation }
        guard case .needsInput(let reason) = session.state, !TerminalSession.isUsersOwn(reason) else { return nil }
        delegation.toldAt = now
        scheduleDelegationSweep(after: Delegation.fallback)
        return waitDescription(session, reason: reason)
    }

    /// Ends a handoff. A wait Sumi was told of and didn't answer goes to the user.
    func stopDelegating(_ session: TerminalSession, why: String, tellSumi: Bool) {
        guard let delegation = session.delegation else { return }
        session.delegation = nil
        session.record(.note, "Sumi stopped handling: " + why)
        if delegation.toldAt != nil { notifyUserOfWait(session) }
        if tellSumi, sumi != nil {
            addToSumiDigest(SumiEvent(label: session.label, kind: .stoppedHandling(why)))
        }
    }

    /// A delegated session started waiting: Sumi hears instead of the user. False when
    /// the user should be notified as usual. Folder trust and sign-in go to Sumi only in Phone
    /// Mode, where it relays them to the user's phone.
    func sumiTakesWait(_ session: TerminalSession, reason: String, now: Date = Date()) -> Bool {
        guard var delegation = session.delegation, let sumi, !sumi.isExitedProcess else { return false }
        guard isPhoneModeOn || !TerminalSession.isUsersOwn(reason) else {
            session.record(.note, reason == TerminalSession.trustReason ? "Left for you: trusting a folder is your call" : "Left for you: signing in is your call")
            return false
        }
        delegation.toldAt = now
        delegation.reminders = 0
        session.delegation = delegation
        addToSumiDigest(SumiEvent(label: session.label,
                                  kind: .needsYou(waitDescription(session, reason: reason), note: delegation.note)),
                        urgent: true)
        scheduleDelegationSweep(after: Delegation.fallback)
        return true
    }

    /// Scope accounting on each state change: a wait ending counts as handled; a used-up scope,
    /// a finished task (`.turn`) or an exit ends the handoff.
    func delegationStateChanged(_ session: TerminalSession, from previous: AgentState, now: Date = Date()) {
        guard var delegation = session.delegation else { return }
        if previous.needsAttention, delegation.toldAt != nil {
            delegation.toldAt = nil
            delegation.reminders = 0
            delegation.handled += 1
        }
        session.delegation = delegation
        if case .exited = session.state {
            stopDelegating(session, why: "it exited", tellSumi: !(isPhoneModeOn && delegation.scope == .phoneMode))
        } else if delegation.isUsedUp(at: now) {
            stopDelegating(session, why: "scope used up", tellSumi: true)
        } else if delegation.scope == .turn, session.state == .idle, previous == .working {
            stopDelegating(session, why: "it finished its task", tellSumi: true)
        }
    }

    /// Waits Sumi hasn't answered in time go to the user; expired handoffs end. In Phone Mode the
    /// user is away from the Mac, so Sumi is reminded first, to push their phone.
    func sweepDelegations(now: Date = Date()) {
        for session in sessions {
            guard var delegation = session.delegation else { continue }
            if delegation.isOverdue(at: now), session.state.needsAttention, isPhoneModeOn,
               delegation.reminders < Delegation.phoneReminders, case .needsInput(let reason) = session.state {
                delegation.reminders += 1
                delegation.toldAt = now
                session.delegation = delegation
                let waited = Int(Delegation.fallback) * delegation.reminders
                addToSumiDigest(SumiEvent(label: session.label, kind: .stillWaiting(
                    waitDescription(session, reason: reason), seconds: waited)), urgent: true)
                scheduleDelegationSweep(after: Delegation.fallback)
            } else if delegation.isOverdue(at: now), session.state.needsAttention {
                let waited = Int(Delegation.fallback) * (delegation.reminders + 1)
                escalate(session, why: "Sumi didn't get an answer within \(waited) s", now: now)
            } else if delegation.isUsedUp(at: now) {
                stopDelegating(session, why: "scope used up", tellSumi: true)
            }
        }
    }

    /// Hands the current wait back to the user, notified as a normal needs-you.
    func escalate(_ session: TerminalSession, why: String, now: Date = Date()) {
        guard var delegation = session.delegation else { return }
        if delegation.toldAt != nil {
            delegation.toldAt = nil
            delegation.reminders = 0
            delegation.handled += 1
        }
        session.delegation = delegation
        session.record(.note, "Left for you: " + why)
        notifyUserOfWait(session)
        if delegation.isUsedUp(at: now) { stopDelegating(session, why: "scope used up", tellSumi: true) }
    }

    /// answer_prompt: approve or deny one permission request of a delegated, waiting session.
    /// Never "always"; risky requests and folder trust go to the user instead. In Phone Mode the
    /// user is talking to Sumi from their phone, so a risky request it relayed may be
    /// approved once the user OK'd it there (`userApproved`).
    func answerForSumi(_ session: TerminalSession, _ answer: PromptAnswer, reason: String?,
                            userApproved: Bool = false) -> Result<String, DelegationError> {
        guard answer != .always else {
            return .failure(DelegationError("never \"always\": approve or deny this one request"))
        }
        guard session.delegation != nil else {
            return .failure(DelegationError("@\(session.label) isn't handed to you; take over a session's waits with handle_waiting only when the user asks"))
        }
        guard case .needsInput(let waiting) = session.state else {
            return .failure(DelegationError("@\(session.label) isn't waiting"))
        }
        guard !TerminalSession.isUsersOwn(waiting) else {
            return .failure(DelegationError(waiting == TerminalSession.trustReason
                ? "trusting a folder is the user's call; they've been notified" : "signing in is the user's call; they've been notified"))
        }
        let approval = approvals[session.id]
        let pending = session.pendingRequest
        guard approval != nil || (pending != nil && pending == waiting) else {
            return .failure(DelegationError(session.pendingQuestion?.mode == .options
                ? "@\(session.label) asked a multiple-choice question: answer it with choose_option"
                : "@\(session.label) asked a question, not for permission: answer it with send_message"))
        }
        let request = approval?.request ?? pending ?? waiting
        let summary = approval?.summary ?? waiting
        if answer == .approve, let why = RiskyRequest.reason(tool: approval?.toolName, request: request, workspace: session.spec.workPath) {
            if phoneModeSince != nil {
                guard userApproved else {
                    return .failure(DelegationError("\(why): ask the user on their phone about exactly this request (\(summary)); "
                        + "if they say yes, call answer_prompt again with user_approved true, otherwise deny"))
                }
                session.record(.note, "Approved from your phone: \(why) (\(summary))")
            } else {
                escalate(session, why: "\(why) (\(summary))")
                return .failure(DelegationError("left for the user: \(why)"))
            }
        }
        let denial = answer == .deny ? (reason ?? "Sumi denied this on the user's behalf.") : nil
        switch self.answer(session, answer, reason: denial) {
        case .success(let done):
            session.record(.note, "Sumi answered: " + (answer == .deny ? "denied " : "allowed ") + summary)
            return .success("\(done) @\(session.label): \(summary)")
        case .failure(let error):
            return .failure(DelegationError(error.description))
        }
    }

    // MARK: - Sumi's hands

    /// Sumi acts on a session the user handed it, or on any agent while Phone Mode is on: there the
    /// user is talking to Sumi from their phone, so what Sumi relays is the user's word.
    private func sumiMayAct(on session: TerminalSession) -> DelegationError? {
        guard session.kind.isAgent, !session.isSumi else { return DelegationError("@\(session.label) isn't an agent") }
        guard isPhoneModeOn || session.delegation != nil else {
            return DelegationError("@\(session.label) isn't handed to you; outside Phone Mode, take over a session's waits with handle_waiting only when the user asks")
        }
        return nil
    }

    /// choose_option: picks option `number` (1-based) of the question the agent is asking.
    func chooseForSumi(_ session: TerminalSession, option number: Int,
                       completion: @escaping (Result<String, DelegationError>) -> Void) {
        if let refusal = sumiMayAct(on: session) { return completion(.failure(refusal)) }
        guard let question = session.pendingQuestion, question.mode == .options else {
            return completion(.failure(DelegationError("@\(session.label) isn't asking a question with options; read_terminal it, and send_message to answer in words")))
        }
        let options = question.items[0].options
        guard options.indices.contains(number - 1) else {
            return completion(.failure(DelegationError("option must be 1–\(options.count)")))
        }
        let label = options[number - 1].label
        answerQuestion(session, option: number - 1) { result in
            switch result {
            case .success:
                session.record(.note, "Sumi answered: \(label)")
                completion(.success("answered @\(session.label): \(label)"))
            case .failure(let error):
                completion(.failure(DelegationError(error.description)))
            }
        }
    }

    /// trust_folder: only on the user's yes, relayed from their phone.
    func trustForSumi(_ session: TerminalSession, userApproved: Bool) -> Result<String, DelegationError> {
        if let refusal = sumiMayAct(on: session) { return .failure(refusal) }
        guard session.state == .needsInput(TerminalSession.trustReason) else {
            return .failure(DelegationError("@\(session.label) isn't asking to trust its folder"))
        }
        guard userApproved else {
            return .failure(DelegationError("ask the user whether to trust \(abbreviateHome(session.spec.workPath)) for @\(session.label); if they say yes, call trust_folder again with user_approved true"))
        }
        switch answer(session, .approve) {
        case .success:
            session.record(.note, "Folder trusted from your phone")
            return .success("trusted \(abbreviateHome(session.spec.workPath)) for @\(session.label)")
        case .failure(let error):
            return .failure(DelegationError(error.description))
        }
    }

    /// sign_in: starts the CLI's device-code sign-in and returns the link and code for the user's phone.
    func signInForSumi(_ session: TerminalSession, completion: @escaping (Result<String, DelegationError>) -> Void) {
        if let refusal = sumiMayAct(on: session) { return completion(.failure(refusal)) }
        guard case .needsInput(let reason) = session.state, reason.hasPrefix("Sign in to ") else {
            return completion(.failure(DelegationError("@\(session.label) isn't asking to sign in")))
        }
        session.signInWithDeviceCode { result in
            switch result {
            case .success(let instructions): completion(.success(instructions))
            case .failure(let error): completion(.failure(DelegationError(error.description)))
            }
        }
    }

    /// interrupt_agent: stops the agent's current turn, as Esc does in its terminal.
    func interruptForSumi(_ session: TerminalSession) -> Result<String, DelegationError> {
        if let refusal = sumiMayAct(on: session) { return .failure(refusal) }
        guard session.state == .working else { return .failure(DelegationError("@\(session.label) isn't working")) }
        _ = session.surface.pressKey(named: "esc")
        session.record(.note, "Interrupted by Sumi")
        return .success("interrupted @\(session.label)")
    }

    /// The normal needs-you, for a wait Sumi didn't take or left.
    private func notifyUserOfWait(_ session: TerminalSession) {
        guard case .needsInput(let reason) = session.state else { return }
        if !userIsLooking(at: session) { session.unread = true }
        guard notifiesUser else { return }
        notifier.post(session: session, title: "@\(session.label) needs you", body: reason, foreground: true)
        if let approval = approvals[session.id] {
            notifier.postApproval(session: session, request: approval.summary, alwaysRule: alwaysRuleText(for: session))
        }
    }

    /// The reason, plus the pending request when it says more, kept short for the digest.
    func waitDescription(_ session: TerminalSession, reason: String) -> String {
        var text = reason
        if let request = approvals[session.id]?.request ?? session.pendingRequest, !reason.contains(request) {
            text += " · request: " + (request.count > 300 ? String(request.prefix(299)) + "…" : request)
        }
        if let question = session.pendingQuestion, question.mode == .options {
            let item = question.items[0]
            text += " · question: " + item.question + " · options: "
                + item.options.enumerated().map { "\($0 + 1). \($1.label)" }.joined(separator: "; ")
                + " (choose_option)"
        } else if reason == TerminalSession.trustReason {
            text += " · folder: \(abbreviateHome(session.spec.workPath)) (trust_folder once the user says yes)"
        } else if reason.hasPrefix("Sign in to ") {
            text += " (sign_in gets a link and code for the user's phone)"
        } else if approvals[session.id] != nil || session.pendingRequest == reason {
            text += " (answer_prompt)"
        }
        return text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private func scheduleDelegationSweep(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0) + 0.5) { [weak self] in
            self?.sweepDelegations()
        }
    }
}

struct DelegationError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
