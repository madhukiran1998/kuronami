import Foundation

enum SessionKind: String, Codable, CaseIterable, Identifiable {
    case claude, codex, shell, server, browser

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .shell: return "Shell"
        case .server: return "Server"
        case .browser: return "Browser"
        }
    }

    var badge: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .shell: return "sh"
        case .server: return "srv"
        case .browser: return "web"
        }
    }

    var isAgent: Bool { self == .claude || self == .codex }
}

/// What a session is doing. Liveness, turn status, and pending user requests collapse into one
/// value here because the sidebar shows one; `source` records which signal set it.
enum AgentState: Equatable {
    case starting
    case working
    case needsInput(String)
    case idle
    case failed(String)
    case exited(Int)
    case running   // shells and servers with a live process

    var key: String {
        switch self {
        case .starting: return "starting"
        case .working: return "working"
        case .needsInput: return "needs-input"
        case .idle: return "idle"
        case .failed: return "failed"
        case .exited: return "exited"
        case .running: return "running"
        }
    }

    var detail: String? {
        switch self {
        case .needsInput(let reason): return reason
        case .failed(let reason): return reason
        case .exited(let code): return "exit \(code)"
        default: return nil
        }
    }

    var needsAttention: Bool {
        if case .needsInput = self { return true }
        return false
    }

    /// Sort order for sidebar groups: what needs you first.
    var groupRank: Int {
        switch self {
        case .needsInput: return 0
        case .failed: return 1
        case .working, .starting: return 2
        case .idle: return 3
        case .running: return 4
        case .exited: return 5
        }
    }

    var groupTitle: String {
        switch self {
        case .needsInput: return "Needs you"
        case .failed: return "Failed"
        case .working, .starting: return "Working"
        case .idle: return "Idle"
        case .running: return "Running"
        case .exited: return "Exited"
        }
    }
}

/// Who chose a terminal's label. Agents may rename terminals that weren't named by the user.
enum LabelSource: String, Codable {
    case user, auto, agent
}

/// Everything needed to (re)create a session. Persisted across app restarts.
struct LaunchSpec: Codable, Identifiable, Equatable {
    var id: UUID
    var label: String
    /// Nil in specs saved before label sources existed; treated as user-chosen.
    var labelSource: LabelSource?
    /// Earlier labels, so messages addressed to an old name still arrive.
    var previousLabels: [String]?
    var kind: SessionKind
    var cwd: String
    /// Server/shell: the command to run. Agents: extra CLI arguments.
    var command: String?
    /// Claude session id or Codex thread id, learned from hooks; enables resume after restart.
    var agentSessionId: String?
    /// Last known one-line summary, so rows aren't blank after a restart.
    var summary: String?
    /// Set when Kuronami created a dedicated worktree for this session.
    var worktreeBranch: String?
    /// Claude's native worktree name (`claude --worktree <name>`); the worktree lives at
    /// `<repo>/.claude/worktrees/<name>` while `cwd` stays the repo root.
    var worktreeName: String?
    /// The branch the worktree was cut from, for diffs and merges.
    var baseBranch: String?
    /// Port reserved for this workspace's dev server ($PORT).
    var port: Int?
    /// Browser: the page it shows, kept current so it reopens there.
    var url: String?
    /// Browser: the agent it belongs to. Its tools act on this browser by default.
    var owner: UUID?
    /// Parked on the shelf instead of taking a tile in split and grid.
    var minimized: Bool?
    /// Agents: which Claude/Codex account it runs on (nil: the default account).
    var account: String?
    /// A shell opened to sign an account in: which kind of account `account` names.
    var accountKind: SessionKind?
    /// Agents: permission mode, model and effort chosen at launch.
    var options: AgentOptions?
    /// Claude: start as a fork of this conversation (`--resume <id> --fork-session`).
    var forkOf: String?
    /// Agents started together on one task share a race id, so the best result can be picked.
    var race: UUID?
    /// The agent behind the sidebar's box: it starts, arranges and closes the other sessions.
    var organizer: Bool?

    /// Where the agent's files actually live.
    var workPath: String {
        if let worktreeName { return (expandTilde(cwd) as NSString).appendingPathComponent(".claude/worktrees/\(worktreeName)") }
        return expandTilde(cwd)
    }
    var createdAt: Date

    var agentMayRename: Bool { (labelSource ?? .user) != .user }

    init(label: String, kind: SessionKind, cwd: String, command: String? = nil) {
        self.id = UUID()
        self.label = normalizeLabel(label)
        self.labelSource = self.label.isEmpty ? .auto : .user
        self.kind = kind
        self.cwd = cwd
        self.command = command?.isEmpty == true ? nil : command
        self.agentSessionId = nil
        self.createdAt = Date()
    }
}
