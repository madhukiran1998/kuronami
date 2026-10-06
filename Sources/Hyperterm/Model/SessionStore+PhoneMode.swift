import Foundation

/// Phone Mode: the user is away and steers Kuronami from their phone through the organizer, so
/// nothing should wait on the Mac. While it's on, Kuronami approves agents' ordinary permission
/// requests itself, every agent's other waits (questions, risky requests) go to the organizer,
/// and the app's own confirmations are skipped. Risky requests still need the user's yes, given
/// to the organizer on their phone.
extension SessionStore {
    var isPhoneModeOn: Bool { phoneModeSince != nil }

    /// Phone Mode rides on Claude's Remote Control, so it exists only while Claude runs the organizer.
    var phoneModeAvailable: Bool { (organizer?.kind ?? Self.chosenOrganizerKind) == .claude }

    /// The user's switch: Phone Mode on, and the organizer's session opened to the phone with Remote Control.
    func startPhoneMode() {
        guard phoneModeAvailable else { return }
        setPhoneMode(true)
        organizer?.openRemoteControl()
    }

    func setPhoneMode(_ on: Bool, now: Date = Date()) {
        if on {
            guard phoneModeSince == nil else { return }
            phoneModeSince = now
            if organizer == nil, !organizerNeedsChoice { startOrganizer() }
            addToOrganizerDigest(OrganizerEvent(label: "kuronami", kind: .phoneMode(true)))
            // What's already waiting: ordinary requests are allowed, the rest go to the organizer.
            for session in sessions where adoptIntoPhoneMode(session) {
                guard case .needsInput(let reason) = session.state else { continue }
                if let approval = approvals[session.id], approvesInPhoneMode(session, approval) {
                    _ = answer(session, .approve)
                } else {
                    _ = organizerTakesWait(session, reason: reason, now: now)
                }
            }
        } else {
            guard phoneModeSince != nil else { return }
            phoneModeSince = nil
            for session in sessions where session.delegation?.scope == .phoneMode {
                stopDelegating(session, why: "Phone Mode is off", tellOrganizer: false)
            }
            addToOrganizerDigest(OrganizerEvent(label: "kuronami", kind: .phoneMode(false)))
        }
    }

    /// Hands an agent's waits to the organizer for as long as Phone Mode lasts; agents started
    /// while it's on are adopted on their first state change. Agents the user handed over with
    /// their own scope keep it. True when it adopted this one.
    @discardableResult
    func adoptIntoPhoneMode(_ session: TerminalSession) -> Bool {
        guard isPhoneModeOn, session.kind.isAgent, !session.isOrganizer, session.delegation == nil else { return false }
        session.delegation = Delegation(scope: .phoneMode, note: nil)
        session.record(.note, "Organizer handling: while Phone Mode is on")
        return true
    }

    /// Ordinary requests Kuronami allows itself in Phone Mode: anything the organizer's guard
    /// wouldn't leave for the user.
    func approvesInPhoneMode(_ session: TerminalSession, _ approval: PendingApproval) -> Bool {
        isPhoneModeOn && !session.isOrganizer
            && RiskyRequest.reason(tool: approval.toolName, request: approval.request, workspace: session.spec.workPath) == nil
    }

    /// The app's own confirmations (starting servers and agents, closing terminals) have no one to
    /// answer them in Phone Mode; the user asked the organizer from their phone instead.
    func confirmUnlessPhoneMode(_ title: String, _ message: String, completion: @escaping (Bool) -> Void) {
        if isPhoneModeOn { completion(true); return }
        confirm(title, message, completion: completion)
    }
}
