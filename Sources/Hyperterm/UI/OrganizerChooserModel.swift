import Foundation

/// A key the organizer's first-run chooser understands.
enum OrganizerChooserKey: Equatable {
    case up, down, confirm, back
    /// 1...9: picks that row.
    case number(Int)

    static func from(keyCode: UInt16, characters: String?) -> OrganizerChooserKey? {
        switch keyCode {
        case 126: return .up
        case 125: return .down
        case 36, 76: return .confirm
        case 53: return .back
        default:
            guard let text = characters, text.count == 1, let digit = Int(text), (1...9).contains(digit) else { return nil }
            return .number(digit)
        }
    }
}

/// Where the chooser is (the CLI step, or one CLI's model step), which row is selected, and a
/// note when a start just failed. The view and the key handling both read and write this.
@MainActor
struct OrganizerChooserModel: Equatable {
    /// Nil on the CLI step; a CLI on its model step.
    var step: SessionKind?
    var selection = 0
    var notice: String?

    enum Outcome: Equatable {
        case none
        case pick(Int)
        case back
    }

    /// Moves the ring (never onto a disabled row), or says what the key chose.
    mutating func handle(_ key: OrganizerChooserKey, count: Int, isEnabled: (Int) -> Bool = { _ in true }) -> Outcome {
        switch key {
        case .up: move(-1, count: count, isEnabled: isEnabled); return .none
        case .down: move(1, count: count, isEnabled: isEnabled); return .none
        case .back: return .back
        case .confirm:
            return (0..<count).contains(selection) && isEnabled(selection) ? .pick(selection) : .none
        case .number(let n):
            guard (1...count).contains(n), isEnabled(n - 1) else { return .none }
            selection = n - 1
            return .pick(n - 1)
        }
    }

    private mutating func move(_ delta: Int, count: Int, isEnabled: (Int) -> Bool) {
        var next = selection + delta
        while (0..<count).contains(next) {
            if isEnabled(next) { selection = next; return }
            next += delta
        }
    }

    /// The model step for `kind`, the recommended row selected so Return starts it.
    static func models(for kind: SessionKind, notice: String? = nil, avoiding failed: String?? = nil) -> OrganizerChooserModel {
        let models = SessionStore.organizerModels(for: kind)
        var selection = models.firstIndex(where: \.recommended) ?? 0
        // After a failure, the failed model is not the one to offer first.
        if let failed, models[safe: selection]?.name == failed {
            selection = models.indices.first { models[$0].name != failed } ?? selection
        }
        return OrganizerChooserModel(step: kind, selection: selection, notice: notice)
    }

    /// The CLI step, the first installed CLI selected.
    static func clis(isEnabled: (SessionKind) -> Bool) -> OrganizerChooserModel {
        let choices = SessionStore.organizerChoices
        return OrganizerChooserModel(step: nil, selection: choices.firstIndex(where: isEnabled) ?? 0)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// The rules around the chooser that aren't about keys.
@MainActor
enum OrganizerOnboarding {
    /// With exactly one organizer-capable CLI installed there is nothing to choose: its model step comes first.
    /// Nil while the look is unfinished, or when several or none are installed.
    static func soleCLI(installed: Set<SessionKind>?, choices: [SessionKind]? = nil) -> SessionKind? {
        guard let installed else { return nil }
        let available = (choices ?? SessionStore.organizerChoices).filter(installed.contains)
        return available.count == 1 ? available[0] : nil
    }

    /// How long after a choice an organizer that dies still counts as one that failed to start.
    static let startWindow: TimeInterval = 10

    enum StartVerdict: Equatable { case waiting, started, failed }

    /// `exited` is nil when there is no organizer session; `launching` is true while Tako is still starting one.
    static func startVerdict(exited: Bool?, launching: Bool, elapsed: TimeInterval) -> StartVerdict {
        switch exited {
        case true?: return .failed
        case false?: return elapsed >= startWindow ? .started : .waiting
        case nil: return launching ? .waiting : .failed
        }
    }

    static func failureMessage(kind: SessionKind, modelTitle: String) -> String {
        "\(kind.displayName) couldn't start with \(modelTitle). Choose another model."
    }
}
