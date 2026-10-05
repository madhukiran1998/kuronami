import Foundation

/// One line in an agent's activity history, built from hooks. Powers the timeline and the
/// "since you left" recap.
struct TimelineEvent: Identifiable, Equatable {
    enum Kind: String { case prompt, tool, edit, approval, test, done, failure, message, note }
    let id = UUID()
    let date: Date
    let kind: Kind
    let text: String
}

/// Claude statusLine telemetry for one session.
struct UsageSnapshot: Equatable {
    var costUSD: Double?
    var contextPercent: Double?
    var model: String?
    var limits: RateLimits?
}

/// Account-wide rate-limit windows (shared by every agent on the account).
struct RateLimits: Equatable, Codable {
    var fiveHourPercent: Double?
    var fiveHourResets: Date?
    var sevenDayPercent: Double?
    var sevenDayResets: Date?

    var highest: Double { max(fiveHourPercent ?? 0, sevenDayPercent ?? 0) }

    /// A saved reading as of `now`: a window that has reset since is back to zero.
    func current(at now: Date = Date()) -> RateLimits {
        var limits = self
        if let reset = fiveHourResets, reset <= now { limits.fiveHourPercent = 0; limits.fiveHourResets = nil }
        if let reset = sevenDayResets, reset <= now { limits.sevenDayPercent = 0; limits.sevenDayResets = nil }
        return limits
    }
}

/// Claude's own todo list, from TaskCreated/TaskCompleted hooks.
struct TaskProgress: Equatable {
    var subjects: [String: String] = [:]
    var completed: Set<String> = []
    var order: [String] = []

    var total: Int { order.count }
    var done: Int { completed.count }
    var current: String? { order.first { !completed.contains($0) }.flatMap { subjects[$0] } }
}

/// The last test run an agent did, from PostToolUse / PostToolUseFailure on test commands.
struct TestEvidence: Equatable {
    var passed: Bool
    var summary: String
    var date: Date
}

/// Size of an agent's uncommitted plus branch changes.
struct DiffStat: Equatable {
    var added: Int
    var removed: Int
    var files: Int

    var isEmpty: Bool { files == 0 }
    var text: String { "+\(added) −\(removed) · \(files) file\(files == 1 ? "" : "s")" }
}

enum PromptAnswer: String { case approve, always, deny }

/// A PermissionRequest hook held open until someone decides.
struct PendingApproval {
    let id = UUID()
    let source: String
    let toolName: String
    let summary: String
    let suggestions: Any?
    let createdAt = Date()
    let reply: ControlServer.Reply
}

enum TestCommand {
    private static let patterns = ["test", "vitest", "jest", "pytest", "rspec", "go test", "cargo test", "xcodebuild test", "mocha", "phpunit", "swift test"]

    static func matches(_ command: String) -> Bool {
        let lower = command.lowercased()
        return patterns.contains { lower.contains($0) }
    }

    /// "48 passed", "3 failed, 45 passed", "Tests: 2 failed" — the line a human would look for.
    static func summary(from output: String, passed: Bool) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let keywords = ["passed", "failed", "failing", "passing", "tests", "error"]
        if let line = lines.reversed().first(where: { line in keywords.contains { line.lowercased().contains($0) } && line.count < 140 }) {
            return line
        }
        return passed ? "tests passed" : "tests failed"
    }
}
