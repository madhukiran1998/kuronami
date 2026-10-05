import Foundation

/// Wire protocol between the Kuronami app and the `ht` CLI / hooks / MCP bridge.
/// One JSON object per line over a Unix domain socket, one request per connection.
enum ControlCommand: String, Codable {
    case list          // list sessions
    case new           // create a session
    case send          // deliver a message into a session (typed into its terminal)
    case read          // read a session's screen text
    case focus         // focus a session in the UI
    case close         // close a session
    case restart       // restart a session with the same launch spec
    case rename        // change a session label
    case hook          // lifecycle event from an agent hook (Claude / Codex)
    case notify        // explicit attention notification
    case key           // press named keys in a terminal (user only)
    case layout        // switch layout: focus | split | grid (text)
    case status        // an agent posts a one-line status for its card (text)
    case approve       // answer a pending prompt: text = approve | always | deny (user only)
    case permission    // PermissionRequest hook, held open until the user decides
    case statusline    // Claude statusLine JSON (cost, context, rate limits)
    case subscribe     // channel long-poll from an agent's MCP server: returns queued messages
    case browser       // start the embedded browser if needed; text = its DevTools endpoint
}

struct ControlRequest: Codable {
    var cmd: ControlCommand
    /// Target session: label (with or without leading @) or session id.
    var target: String?
    /// Session id of the caller, taken from $HT_SESSION_ID. Used as the sender of messages.
    var from: String?
    var label: String?
    var kind: String?
    var cwd: String?
    var command: String?
    var text: String?
    var lines: Int?
    /// Hook source, e.g. "claude" or "codex-notify".
    var source: String?
    /// Raw hook payload (JSON string as received on stdin/argv).
    var payload: String?
    /// For `send`: type the text and press Enter (default true). False pastes without submitting.
    var submit: Bool?
    /// For `key`: names like "enter", "down", "esc", "tab", "y", "ctrl-c".
    var keys: [String]?
    /// For `new`: give an agent its own git worktree and branch.
    var worktree: Bool?
    /// For `new`: the Claude/Codex account an agent runs on.
    var account: String?
    /// For `hook`: when the hook process started (continuous clock, ns), to order events.
    var sentAt: UInt64?
}

struct SessionInfo: Codable, Equatable {
    var id: String
    var label: String
    var kind: String
    var state: String
    var stateDetail: String?
    var summary: String?
    var title: String?
    var cwd: String
    var command: String?
    var ports: [Int]
    var unread: Bool
    var agentSessionId: String?
    /// "user", "auto", or "agent".
    var labelSource: String?
    var activity: String?
    var project: String?
    var branch: String?
}

struct ControlResponse: Codable {
    var ok: Bool
    /// For `subscribe`: messages to push into the session as channel events.
    var messages: [String]?
    var error: String?
    var sessions: [SessionInfo]?
    var session: SessionInfo?
    var text: String?
    /// For `browser`: the DevTools endpoint the browser is actually listening on.
    var endpoint: String?

    static func success(text: String? = nil) -> ControlResponse {
        ControlResponse(ok: true, text: text)
    }

    static func failure(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: message)
    }
}

enum ControlPaths {
    /// ~/.hyperterm: short and space-free because these paths are typed into shells and
    /// embedded in agent configs. $HT_HOME moves it, so a dev build (scripts/run.sh) keeps its
    /// sessions, socket and browser profile apart from the installed app's.
    static var supportDirectory: URL {
        if let env = ProcessInfo.processInfo.environment["HT_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hyperterm", isDirectory: true)
    }

    /// $HT_SOCKET wins so sessions always talk to the app instance that spawned them.
    static var socketPath: String {
        if let env = ProcessInfo.processInfo.environment["HT_SOCKET"], !env.isEmpty { return env }
        return supportDirectory.appendingPathComponent("control.sock").path
    }
}

/// Default names for new agents and shells, used in order: short to say, and each one's first
/// letter also finds it ("b" is @bravo).
let phoneticLabels = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india",
                      "juliet", "kilo", "lima", "mike", "november", "oscar", "papa", "quebec", "romeo",
                      "sierra", "tango", "uniform", "victor", "whiskey", "xray", "yankee", "zulu"]

/// Normalizes "@api", "api", " API " to "api".
func normalizeLabel(_ raw: String) -> String {
    var label = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if label.hasPrefix("@") { label.removeFirst() }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    label = String(label.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    return label
}
