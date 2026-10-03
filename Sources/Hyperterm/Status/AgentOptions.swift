import Foundation

/// How much an agent may do without asking. One vocabulary for both CLIs, translated to each
/// one's own flags.
enum PermissionMode: String, Codable, CaseIterable, Identifiable {
    /// Asks before commands and edits.
    case supervised
    /// Edits files freely; still asks before commands.
    case acceptEdits
    /// Reads and plans; changes nothing until you approve the plan.
    case plan
    /// Never asks. For sandboxes and throwaway worktrees.
    case fullAccess

    var id: String { rawValue }

    var title: String {
        switch self {
        case .supervised: return "Ask First"
        case .acceptEdits: return "Accept Edits"
        case .plan: return "Plan"
        case .fullAccess: return "Full Access"
        }
    }

    var detail: String {
        switch self {
        case .supervised: return "Asks before running commands or editing files."
        case .acceptEdits: return "Edits files freely; asks before running commands."
        case .plan: return "Explores and proposes a plan; changes nothing until you approve it."
        case .fullAccess: return "Never asks. Use in worktrees you can throw away."
        }
    }

    var symbol: String {
        switch self {
        case .supervised: return "hand.raised"
        case .acceptEdits: return "pencil"
        case .plan: return "list.bullet.clipboard"
        case .fullAccess: return "bolt"
        }
    }
}

/// Codex's reasoning effort (`model_reasoning_effort`).
enum ReasoningEffort: String, Codable, CaseIterable, Identifiable {
    case low, medium, high

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// The two agent CLIs, as far as their flags are concerned.
enum AgentCLI {
    case claude, codex
}

/// Per-agent launch choices. Nil fields leave the CLI's own configuration in charge.
struct AgentOptions: Codable, Equatable {
    var mode: PermissionMode?
    var model: String?
    var effort: ReasoningEffort?

    var isEmpty: Bool { mode == nil && (model ?? "").isEmpty && effort == nil }

    /// Claude Code's model aliases always resolve to the newest model of each tier.
    static let claudeModels = ["opus", "sonnet", "haiku"]

    /// CLI arguments for these choices. Every value is a fixed flag or passes the model check,
    /// so nothing here needs shell quoting beyond what `shellQuote` already adds to the model.
    func arguments(for cli: AgentCLI) -> [String] {
        var args: [String] = []
        if let model = model.flatMap(Self.validModel) {
            args += [cli == .claude ? "--model" : "-m", model]
        }
        switch cli {
        case .claude:
            if let mode {
                let value: String
                switch mode {
                case .supervised: value = "default"
                case .acceptEdits: value = "acceptEdits"
                case .plan: value = "plan"
                case .fullAccess: value = "bypassPermissions"
                }
                args += ["--permission-mode", value]
            }
        case .codex:
            if let effort { args += ["-c", "model_reasoning_effort=\"\(effort.rawValue)\""] }
            switch mode {
            case .supervised?: args += ["--ask-for-approval", "untrusted", "--sandbox", "workspace-write"]
            case .acceptEdits?: args += ["--full-auto"]
            case .plan?: args += ["--ask-for-approval", "on-request", "--sandbox", "read-only"]
            case .fullAccess?: args += ["--dangerously-bypass-approvals-and-sandbox"]
            case nil: break
            }
        }
        return args
    }

    /// Model names are typed into a shell, so only plain identifiers are accepted:
    /// letters, digits, dot, dash, underscore, colon, slash, brackets ("opus[1m]").
    static func validModel(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:/[]"))
        guard (1...80).contains(value.count), value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }

    /// One short line for a card or the inspector: "Opus · Plan".
    var summary: String? {
        let parts = [model.flatMap(Self.validModel).map { $0.prefix(1).uppercased() + $0.dropFirst() },
                     effort.map { "\($0.title) effort" }, mode?.title].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
